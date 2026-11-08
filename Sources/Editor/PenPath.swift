import CutLine
import DocumentModel
import Foundation

public struct PenAnchor: Equatable {
    public enum Kind: Equatable {
        /// Handles move independently.
        case corner
        /// Handles stay on one line through the anchor; each keeps its own length.
        case smooth
        /// Handles stay on one line and keep the same length.
        case symmetric
    }

    public var position: Point
    /// Control point on the incoming side, in the same coordinates as `position`. Nil means no handle (a straight side).
    public var handleIn: Point?
    public var handleOut: Point?
    public var kind: Kind

    public init(_ position: Point, handleIn: Point? = nil, handleOut: Point? = nil, kind: Kind = .corner) {
        self.position = position; self.handleIn = handleIn; self.handleOut = handleOut; self.kind = kind
    }
}

public enum PenHit: Equatable {
    case anchor(Int)
    case handleIn(Int)
    case handleOut(Int)
    /// On the curve between anchor `index` and the next one, at parameter `t` (0...1).
    case segment(index: Int, t: Double)
}

/// An editable Bezier path: the model behind the pen tool. Click adds a corner point, click and drag adds a smooth
/// point with mirrored handles, clicking the first point closes the path. Afterwards anchors and handles can be
/// moved, points inserted or deleted, and corners and curves converted into each other.
public struct PenPath: Equatable {
    public var anchors: [PenAnchor]
    public var isClosed: Bool

    public init(anchors: [PenAnchor] = [], isClosed: Bool = false) {
        self.anchors = anchors; self.isClosed = isClosed
    }

    // MARK: Drawing with the pen

    /// Starts a point at `p` (mouse down). Follow with `dragHandle(to:)` while the button is held.
    public mutating func addAnchor(at p: Point) {
        anchors.append(PenAnchor(p))
    }

    /// While the button is still down after `addAnchor`: pulls out symmetric handles, the way the pen tool does.
    public mutating func dragHandle(to p: Point) {
        guard let i = anchors.indices.last else { return }
        let a = anchors[i].position
        if (p - a).length < 1e-9 {
            anchors[i].handleIn = nil; anchors[i].handleOut = nil; anchors[i].kind = .corner
            return
        }
        anchors[i].handleOut = p
        anchors[i].handleIn = a + (a - p)
        anchors[i].kind = .symmetric
    }

    /// True if `p` is within `threshold` of the first point, so a click there should close the path.
    public func isNearStart(_ p: Point, threshold: Double) -> Bool {
        guard anchors.count >= 3, !isClosed, let first = anchors.first else { return false }
        return (first.position - p).length <= threshold
    }

    public mutating func close() {
        if anchors.count >= 2 { isClosed = true }
    }

    // MARK: Conversion

    public func toPathData() -> PathData {
        guard let first = anchors.first else { return PathData() }
        var e: [PathData.Element] = [.move(first.position)]
        let count = isClosed ? anchors.count : anchors.count - 1
        for i in 0..<max(count, 0) {
            let a = anchors[i], b = anchors[(i + 1) % anchors.count]
            if a.handleOut == nil && b.handleIn == nil {
                // The closing straight side is drawn by the close itself.
                if !(isClosed && i == count - 1) { e.append(.line(b.position)) }
            } else {
                e.append(.cubic(a.handleOut ?? a.position, b.handleIn ?? b.position, b.position))
            }
        }
        if isClosed { e.append(.close) }
        return PathData(elements: e)
    }

    /// Reads the first subpath of a path back into anchors and handles.
    public init(pathData: PathData) {
        var anchors: [PenAnchor] = []
        var closed = false
        loop: for el in pathData.elements {
            switch el {
            case .move(let p):
                if !anchors.isEmpty { break loop }
                anchors.append(PenAnchor(p))
            case .line(let p):
                anchors.append(PenAnchor(p))
            case .cubic(let c1, let c2, let p):
                if !anchors.isEmpty, c1 != anchors[anchors.count - 1].position { anchors[anchors.count - 1].handleOut = c1 }
                anchors.append(PenAnchor(p, handleIn: c2 != p ? c2 : nil))
            case .close:
                closed = true
                break loop
            }
        }
        // A closed path whose last curve ends on the first point: merge the duplicate.
        if closed, anchors.count > 1, let f = anchors.first, let l = anchors.last, (f.position - l.position).length < 1e-9 {
            anchors[0].handleIn = l.handleIn
            anchors.removeLast()
        }
        for i in anchors.indices { anchors[i].kind = Self.inferKind(anchors[i]) }
        self.anchors = anchors
        self.isClosed = closed
    }

    static func inferKind(_ a: PenAnchor) -> PenAnchor.Kind {
        guard let hi = a.handleIn, let ho = a.handleOut else { return .corner }
        let vi = hi - a.position, vo = ho - a.position
        let li = vi.length, lo = vo.length
        guard li > 1e-9, lo > 1e-9 else { return .corner }
        let straight = abs(vi.x * vo.y - vi.y * vo.x) / (li * lo) < 1e-6 && vi.dot(vo) < 0
        if !straight { return .corner }
        return abs(li - lo) < 1e-6 * max(li, lo) ? .symmetric : .smooth
    }

    public var bounds: Rect2? { toPathData().bounds }

    // MARK: Editing

    public mutating func moveAnchor(_ i: Int, to p: Point) {
        guard anchors.indices.contains(i) else { return }
        let d = p - anchors[i].position
        anchors[i].position = p
        if let h = anchors[i].handleIn { anchors[i].handleIn = h + d }
        if let h = anchors[i].handleOut { anchors[i].handleOut = h + d }
    }

    public enum Side { case handleIn, handleOut }

    /// Moves one handle. On a smooth or symmetric anchor the other handle follows to keep the curve smooth.
    public mutating func moveHandle(_ i: Int, _ side: Side, to p: Point) {
        guard anchors.indices.contains(i) else { return }
        let a = anchors[i].position
        let v = p - a
        switch side {
        case .handleIn: anchors[i].handleIn = p
        case .handleOut: anchors[i].handleOut = p
        }
        guard v.length > 1e-9 else { return }
        let otherCurrent = side == .handleIn ? anchors[i].handleOut : anchors[i].handleIn
        let opposite: Point?
        switch anchors[i].kind {
        case .corner: opposite = nil
        case .symmetric: opposite = a - v
        case .smooth:
            let length = otherCurrent.map { ($0 - a).length } ?? v.length
            opposite = a - v.normalized() * length
        }
        if let opposite {
            if side == .handleIn { anchors[i].handleOut = opposite } else { anchors[i].handleIn = opposite }
        }
    }

    /// Splits the curve after anchor `index` at `t` with a new anchor that keeps the shape exactly.
    @discardableResult
    public mutating func insertAnchor(afterSegment index: Int, at t: Double) -> Int? {
        guard anchors.indices.contains(index), t > 1e-6, t < 1 - 1e-6 else { return nil }
        let next = (index + 1) % anchors.count
        if !isClosed && index == anchors.count - 1 { return nil }
        let a = anchors[index], b = anchors[next]
        let p0 = a.position, p1 = a.handleOut ?? a.position, p2 = b.handleIn ?? b.position, p3 = b.position
        func lerp(_ u: Point, _ v: Point) -> Point { u + (v - u) * t }
        let q0 = lerp(p0, p1), q1 = lerp(p1, p2), q2 = lerp(p2, p3)
        let r0 = lerp(q0, q1), r1 = lerp(q1, q2)
        let s = lerp(r0, r1)
        let straight = a.handleOut == nil && b.handleIn == nil
        anchors[index].handleOut = straight ? nil : q0
        anchors[next].handleIn = straight ? nil : q2
        let inserted = PenAnchor(s, handleIn: straight ? nil : r0, handleOut: straight ? nil : r1, kind: straight ? .corner : .smooth)
        let at = index + 1
        anchors.insert(inserted, at: at)
        return at
    }

    /// Removes an anchor; the neighbours keep their own handles.
    public mutating func deleteAnchor(_ i: Int) {
        guard anchors.indices.contains(i) else { return }
        anchors.remove(at: i)
        if anchors.count < 3 { isClosed = false }
    }

    /// Corner to smooth (handles are made from the neighbours) or smooth/symmetric back to corner (handles removed).
    public mutating func toggleSmooth(_ i: Int) {
        guard anchors.indices.contains(i) else { return }
        if anchors[i].kind == .corner {
            let n = anchors.count
            let prev = (i > 0 || isClosed) ? anchors[(i - 1 + n) % n].position : nil
            let next = (i < n - 1 || isClosed) ? anchors[(i + 1) % n].position : nil
            let a = anchors[i].position
            let direction = ((next ?? a) - (prev ?? a))
            guard direction.length > 1e-9 else { return }
            let tangent = direction.normalized()
            let inLength = prev.map { (a - $0).length / 3 } ?? 0
            let outLength = next.map { ($0 - a).length / 3 } ?? 0
            anchors[i].handleIn = prev == nil ? nil : a - tangent * inLength
            anchors[i].handleOut = next == nil ? nil : a + tangent * outLength
            anchors[i].kind = .smooth
        } else {
            anchors[i].handleIn = nil
            anchors[i].handleOut = nil
            anchors[i].kind = .corner
        }
    }

    // MARK: Hit testing

    /// What is under `p`: handles first, then anchors, then the curve itself. `tolerance` is in the path's units.
    public func hitTest(_ p: Point, tolerance: Double) -> PenHit? {
        for (i, a) in anchors.enumerated() {
            if let h = a.handleOut, (h - p).length <= tolerance { return .handleOut(i) }
            if let h = a.handleIn, (h - p).length <= tolerance { return .handleIn(i) }
        }
        for (i, a) in anchors.enumerated() where (a.position - p).length <= tolerance { return .anchor(i) }
        var best: (Double, PenHit)?
        let count = isClosed ? anchors.count : anchors.count - 1
        for i in 0..<max(count, 0) {
            let a = anchors[i], b = anchors[(i + 1) % anchors.count]
            let seg = CubicBezier(a.position, a.handleOut ?? a.position, b.handleIn ?? b.position, b.position)
            let (dist, t) = Self.closest(on: seg, to: p)
            if dist <= tolerance, best == nil || dist < best!.0 { best = (dist, .segment(index: i, t: t)) }
        }
        return best?.1
    }

    static func closest(on seg: CubicBezier, to p: Point) -> (Double, Double) {
        var bestT = 0.0, bestD = Double.infinity
        let steps = 48
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let d = (seg.point(at: t) - p).length
            if d < bestD { bestD = d; bestT = t }
        }
        // Refine around the best sample.
        var lo = max(0, bestT - 1.0 / Double(steps)), hi = min(1, bestT + 1.0 / Double(steps))
        for _ in 0..<30 {
            let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
            if (seg.point(at: m1) - p).length < (seg.point(at: m2) - p).length { hi = m2 } else { lo = m1 }
        }
        let t = (lo + hi) / 2
        return ((seg.point(at: t) - p).length, t)
    }
}
