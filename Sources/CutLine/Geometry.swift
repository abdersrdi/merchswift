import Foundation

public struct Point: Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
    static func * (a: Point, s: Double) -> Point { Point(a.x * s, a.y * s) }
    var length: Double { (x * x + y * y).squareRoot() }
    func dot(_ o: Point) -> Double { x * o.x + y * o.y }
    func normalized() -> Point {
        let l = length
        return l > 1e-12 ? Point(x / l, y / l) : Point(0, 0)
    }
}

public struct CubicBezier: Equatable {
    public var p0: Point, p1: Point, p2: Point, p3: Point
    public init(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point) {
        self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3
    }

    public func point(at t: Double) -> Point {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return Point(a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                     a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }
}

/// One closed outline made of cubic Bezier segments. Segment i ends where segment i+1 starts,
/// and the last segment ends at the first segment's start.
public struct Contour: Equatable {
    public var segments: [CubicBezier]
    public init(segments: [CubicBezier]) { self.segments = segments }

    /// Points along the outline, `perSegment` samples per curve (the closing point is not repeated).
    public func flattened(perSegment: Int = 8) -> [Point] {
        var out: [Point] = []
        out.reserveCapacity(segments.count * perSegment)
        for s in segments {
            for i in 0..<perSegment { out.append(s.point(at: Double(i) / Double(perSegment))) }
        }
        return out
    }

    public var bounds: (min: Point, max: Point)? {
        let pts = flattened(perSegment: 16)
        guard var lo = pts.first else { return nil }
        var hi = lo
        for p in pts { lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y) }
        return (lo, hi)
    }

    func mapped(_ f: (Point) -> Point) -> Contour {
        Contour(segments: segments.map { CubicBezier(f($0.p0), f($0.p1), f($0.p2), f($0.p3)) })
    }
}

/// The cut line: one closed contour per separate shape. Units depend on where it came from
/// (pixels straight out of the generator, millimetres after `scaled`).
public struct CutPath: Equatable {
    public var contours: [Contour]
    public init(contours: [Contour]) { self.contours = contours }

    public var segmentCount: Int { contours.reduce(0) { $0 + $1.segments.count } }

    public var bounds: (min: Point, max: Point)? {
        var lo: Point?, hi: Point?
        for c in contours {
            guard let b = c.bounds else { continue }
            lo = Point(min(lo?.x ?? b.min.x, b.min.x), min(lo?.y ?? b.min.y, b.min.y))
            hi = Point(max(hi?.x ?? b.max.x, b.max.x), max(hi?.y ?? b.max.y, b.max.y))
        }
        if let lo, let hi { return (lo, hi) }
        return nil
    }

    public func scaled(by s: Double) -> CutPath {
        CutPath(contours: contours.map { $0.mapped { Point($0.x * s, $0.y * s) } })
    }

    /// Image coordinates (y down) to page coordinates (y up) for a page `height` tall, then scaled.
    public func flippedY(height: Double, scale: Double = 1) -> CutPath {
        CutPath(contours: contours.map { $0.mapped { Point($0.x * scale, (height - $0.y) * scale) } })
    }

    /// True if any outline crosses itself or another outline (checked on the flattened curves).
    public func hasSelfIntersections(perSegment: Int = 6) -> Bool {
        var polys = contours.map { $0.flattened(perSegment: perSegment) }
        polys = polys.filter { $0.count > 3 }
        var edges: [(Point, Point, Int, Int)] = []   // a, b, polygon, index
        for (pi, poly) in polys.enumerated() {
            for i in 0..<poly.count { edges.append((poly[i], poly[(i + 1) % poly.count], pi, i)) }
        }
        for i in 0..<edges.count {
            for j in (i + 1)..<edges.count {
                let e = edges[i], f = edges[j]
                if e.2 == f.2 {
                    let n = polys[e.2].count
                    let d = abs(e.3 - f.3)
                    if d <= 1 || d == n - 1 { continue }   // neighbours share an endpoint
                }
                if Self.segmentsCross(e.0, e.1, f.0, f.1) { return true }
            }
        }
        return false
    }

    static func segmentsCross(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        func orient(_ p: Point, _ q: Point, _ r: Point) -> Double { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        let o1 = orient(a, b, c), o2 = orient(a, b, d), o3 = orient(c, d, a), o4 = orient(c, d, b)
        return ((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0)) && ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0))
    }
}
