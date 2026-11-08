import CutLine
import DocumentModel
import Foundation

public enum BooleanOperation: String, CaseIterable {
    case union, intersect
    /// The subject minus the clip.
    case subtract
}

/// Union, intersection and difference of filled paths (non-zero fill rule, holes through reversed outlines).
///
/// Method: flatten both paths to polygons; cut every edge where it crosses another; keep, for each shape, only the
/// edges that really bound it, oriented with the inside on the left; classify each piece as inside or outside the
/// other shape; select pieces by the operation; join them into closed outlines. Overlapping edges that both shapes
/// share are decided by their directions, so touching and identical shapes work. Because it classifies pieces
/// instead of intersecting regions, self-overlapping input (a bow tie, a five-point star) works too.
public enum PathBoolean {
    private struct Key: Hashable { var x: Int64; var y: Int64 }
    private struct Edge { var a: Point; var b: Point }

    private static let grid = 1e-6                  // coordinates snap to a millionth of a millimetre
    private static let sideProbe = 1e-4             // how far off an edge to look for "inside"

    public static func perform(_ op: BooleanOperation, subject: PathData, clip: PathData,
                               flatness: Double = 0.01, fitTolerance: Double = 0.01) -> PathData {
        let a = loops(of: subject, flatness: flatness)
        let b = loops(of: clip, flatness: flatness)

        switch op {
        case .union:
            if a.isEmpty { return fit(b, fitTolerance) }
            if b.isEmpty { return fit(a, fitTolerance) }
        case .intersect:
            if a.isEmpty || b.isEmpty { return PathData() }
        case .subtract:
            if a.isEmpty { return PathData() }
            if b.isEmpty { return fit(a, fitTolerance) }
        }

        // 1. The true boundary of each shape, inside on the left.
        let boundaryA = boundary(of: a), boundaryB = boundary(of: b)

        // 2. Cut each shape's edges where the other shape crosses them.
        let piecesA = split(boundaryA, against: boundaryB)
        let piecesB = split(boundaryB, against: boundaryA)

        // 3. Pieces that both shapes share.
        func undirected(_ e: Edge) -> [Key] {
            let k1 = key(e.a), k2 = key(e.b)
            return k1.x < k2.x || (k1.x == k2.x && k1.y <= k2.y) ? [k1, k2] : [k2, k1]
        }
        var shared: [[Key]: (a: Edge, b: Edge)] = [:]
        var inB: [[Key]: Edge] = [:]
        for e in piecesB { inB[undirected(e)] = e }
        for e in piecesA { if let other = inB[undirected(e)] { shared[undirected(e)] = (e, other) } }

        // 4. Select.
        var chosen: [Edge] = []
        for e in piecesA {
            if let pair = shared[undirected(e)] {
                let same = key(pair.a.a) == key(pair.b.a)
                switch op {
                case .union, .intersect: if same { chosen.append(e) }
                case .subtract: if !same { chosen.append(e) }
                }
                continue
            }
            let inside = contains(b, mid(e))
            switch op {
            case .union: if !inside { chosen.append(e) }
            case .intersect: if inside { chosen.append(e) }
            case .subtract: if !inside { chosen.append(e) }
            }
        }
        for e in piecesB where shared[undirected(e)] == nil {
            let inside = contains(a, mid(e))
            switch op {
            case .union: if !inside { chosen.append(e) }
            case .intersect: if inside { chosen.append(e) }
            case .subtract: if inside { chosen.append(Edge(a: e.b, b: e.a)) }
            }
        }

        // 5. Join into outlines.
        return fit(join(chosen), fitTolerance)
    }

    // MARK: Polygons

    private static func loops(of path: PathData, flatness: Double) -> [[Point]] {
        path.flattened(tolerance: flatness).compactMap { sub in
            var pts: [Point] = []
            for p in sub.points {
                let q = snap(p)
                if pts.last.map({ ($0 - q).length > grid / 2 }) ?? true { pts.append(q) }
            }
            if let f = pts.first, let l = pts.last, (f - l).length <= grid / 2 { pts.removeLast() }
            return pts.count >= 3 ? pts : nil
        }
    }

    private static func snap(_ p: Point) -> Point { Point((p.x / grid).rounded() * grid, (p.y / grid).rounded() * grid) }
    private static func key(_ p: Point) -> Key { Key(x: Int64((p.x / grid).rounded()), y: Int64((p.y / grid).rounded())) }
    private static func mid(_ e: Edge) -> Point { Point((e.a.x + e.b.x) / 2, (e.a.y + e.b.y) / 2) }

    /// Non-zero winding test against a set of loops.
    private static func contains(_ loops: [[Point]], _ p: Point) -> Bool {
        var winding = 0
        for poly in loops {
            for i in 0..<poly.count {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                if a.y <= p.y {
                    if b.y > p.y && (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) > 0 { winding += 1 }
                } else if b.y <= p.y && (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) < 0 {
                    winding -= 1
                }
            }
        }
        return winding != 0
    }

    /// Edges that separate inside from outside, each directed so the inside is on its left. Interior seams, where
    /// the shape overlaps itself, are dropped.
    private static func boundary(of loops: [[Point]]) -> [Edge] {
        var edges: [Edge] = []
        for poly in loops {
            for i in 0..<poly.count {
                let e = Edge(a: poly[i], b: poly[(i + 1) % poly.count])
                if key(e.a) != key(e.b) { edges.append(e) }
            }
        }
        var out: [Edge] = []
        var seen = Set<[Key]>()
        for piece in split(edges, against: edges, selfPass: true) {
            let d = piece.b - piece.a
            let len = d.length
            guard len > 1e-12 else { continue }
            let left = Point(-d.y / len, d.x / len)
            let m = mid(piece)
            let l = contains(loops, m + left * sideProbe), r = contains(loops, m - left * sideProbe)
            var e = piece
            if l && !r { } else if !l && r { e = Edge(a: piece.b, b: piece.a) } else { continue }
            let k1 = key(e.a), k2 = key(e.b)
            let id = [k1, k2]
            if seen.insert(id).inserted { out.append(e) }
        }
        return out
    }

    // MARK: Splitting

    /// Cuts each edge of `edges` at every point where an edge of `others` crosses or touches it,
    /// including the ends of overlapping collinear edges.
    private static func split(_ edges: [Edge], against others: [Edge], selfPass: Bool = false) -> [Edge] {
        var out: [Edge] = []
        // Sort the others by their left edge so far-away candidates can be skipped.
        let sorted = others.indices.sorted { min(others[$0].a.x, others[$0].b.x) < min(others[$1].a.x, others[$1].b.x) }
        let lefts = sorted.map { min(others[$0].a.x, others[$0].b.x) }

        for (i, e) in edges.enumerated() {
            let r = e.b - e.a
            let rr = r.dot(r)
            guard rr > 0 else { continue }
            // Where to cut: a position along the edge and, when the cut is at another edge's end, that exact point,
            // so both shapes' pieces end on identical nodes.
            var cuts: [(t: Double, point: Point?)] = [(0, nil), (1, nil)]
            let eMinX = min(e.a.x, e.b.x), eMaxX = max(e.a.x, e.b.x)
            let eMinY = min(e.a.y, e.b.y), eMaxY = max(e.a.y, e.b.y)

            // Candidates whose left edge is not beyond this edge's right edge.
            var hi = lefts.count
            var lo = 0
            while lo < hi { let m = (lo + hi) / 2; if lefts[m] <= eMaxX + 1e-9 { lo = m + 1 } else { hi = m } }
            for pos in 0..<lo {
                let j = sorted[pos]
                if selfPass && j == i { continue }
                let f = others[j]
                if max(f.a.x, f.b.x) < eMinX - 1e-9 || max(f.a.y, f.b.y) < eMinY - 1e-9 || min(f.a.y, f.b.y) > eMaxY + 1e-9 { continue }
                let s = f.b - f.a
                let denom = r.x * s.y - r.y * s.x
                let qp = f.a - e.a
                if abs(denom) < 1e-12 * max(1, r.length * s.length) {
                    // Parallel: split at the other edge's ends if it lies on this line.
                    let distance = abs(qp.x * r.y - qp.y * r.x) / r.length
                    if distance <= 2 * grid {
                        for p in [f.a, f.b] {
                            let t = (p - e.a).dot(r) / rr
                            if t > 1e-9 && t < 1 - 1e-9 { cuts.append((t, p)) }
                        }
                    }
                } else {
                    let t = (qp.x * s.y - qp.y * s.x) / denom
                    let u = (qp.x * r.y - qp.y * r.x) / denom
                    guard t > 1e-9, t < 1 - 1e-9, u > -1e-9, u < 1 + 1e-9 else { continue }
                    if abs(u) < 1e-9 { cuts.append((t, f.a)) } else if abs(u - 1) < 1e-9 { cuts.append((t, f.b)) } else { cuts.append((t, nil)) }
                }
            }
            cuts.sort { $0.t < $1.t }
            var prev = e.a
            for c in cuts.dropFirst() {
                let p = c.t >= 1 ? e.b : (c.point ?? snap(e.a + r * c.t))
                if key(p) != key(prev) { out.append(Edge(a: prev, b: p)); prev = p }
            }
        }
        return out
    }

    // MARK: Joining

    private static func join(_ edges: [Edge]) -> [[Point]] {
        var outgoing: [Key: [Int]] = [:]
        for (i, e) in edges.enumerated() { outgoing[key(e.a), default: []].append(i) }
        var used = [Bool](repeating: false, count: edges.count)
        var loops: [[Point]] = []

        for start in 0..<edges.count where !used[start] {
            var loop: [Point] = []
            var current = start
            let startKey = key(edges[start].a)
            var closed = false
            var guardCount = 0
            while true {
                used[current] = true
                loop.append(edges[current].a)
                let endKey = key(edges[current].b)
                if endKey == startKey { closed = true; break }
                let dir = edges[current].b - edges[current].a
                var best: Int?
                var bestAngle = -Double.infinity
                for c in outgoing[endKey] ?? [] where !used[c] {
                    let d = edges[c].b - edges[c].a
                    let angle = atan2(dir.x * d.y - dir.y * d.x, dir.dot(d))   // most left turn first
                    if angle > bestAngle { bestAngle = angle; best = c }
                }
                guard let next = best else { break }
                current = next
                guardCount += 1
                if guardCount > edges.count { break }
            }
            if closed { loops.append(simplify(loop)) }
        }
        return loops.filter { $0.count >= 3 && abs(area($0)) > 1e-9 }
    }

    /// Removes vertices that sit on a straight line between their neighbours.
    private static func simplify(_ pts: [Point]) -> [Point] {
        var p = pts
        var changed = true
        while changed && p.count > 3 {
            changed = false
            var i = 0
            while i < p.count && p.count > 3 {
                let a = p[(i - 1 + p.count) % p.count], b = p[i], c = p[(i + 1) % p.count]
                let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
                let scale = max((b - a).length * (c - b).length, 1e-12)
                if abs(cross) / scale < 1e-9 && (b - a).dot(c - b) > 0 { p.remove(at: i); changed = true } else { i += 1 }
            }
        }
        return p
    }

    static func area(_ pts: [Point]) -> Double {
        var s = 0.0
        for i in 0..<pts.count {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            s += p.x * q.y - q.x * p.y
        }
        return s / 2
    }

    // MARK: Output

    private static func fit(_ loops: [[Point]], _ tolerance: Double) -> PathData {
        var elements: [PathData.Element] = []
        for loop in loops {
            guard let contour = PolygonFit.fitClosed(loop, tolerance: tolerance) else { continue }
            guard let first = contour.segments.first else { continue }
            elements.append(.move(first.p0))
            for (i, s) in contour.segments.enumerated() {
                if isStraight(s) {
                    // The closing straight side is drawn by the close itself.
                    if i == contour.segments.count - 1 && (s.p3 - first.p0).length < 1e-9 { continue }
                    elements.append(.line(s.p3))
                } else {
                    elements.append(.cubic(s.p1, s.p2, s.p3))
                }
            }
            elements.append(.close)
        }
        return PathData(elements: elements)
    }

    private static func isStraight(_ s: CubicBezier) -> Bool {
        let d = s.p3 - s.p0
        let len = d.length
        if len < 1e-12 { return false }
        func off(_ p: Point) -> Double { abs((p.x - s.p0.x) * d.y - (p.y - s.p0.y) * d.x) / len }
        return off(s.p1) < 1e-7 && off(s.p2) < 1e-7
    }
}

public extension PathData {
    /// Sum of each closed outline's signed area, so an outline wound the other way (a hole) subtracts.
    func signedArea(flatness: Double = 0.01) -> Double {
        flattened(tolerance: flatness).filter { $0.closed }.reduce(0) { $0 + PathBoolean.area($1.points) }
    }

    var closedSubpathCount: Int { elements.filter { $0 == .close }.count }
}
