import CutLine
import Foundation

/// A vector path in the layer's own coordinates (millimetres, y down).
public struct PathData: Codable, Equatable {
    public enum Element: Codable, Equatable {
        case move(Point)
        case line(Point)
        case cubic(Point, Point, Point)
        case close
    }

    public var elements: [Element]
    public init(elements: [Element] = []) { self.elements = elements }

    public static func rect(_ r: Rect2) -> PathData {
        PathData(elements: [.move(Point(r.minX, r.minY)), .line(Point(r.maxX, r.minY)),
                            .line(Point(r.maxX, r.maxY)), .line(Point(r.minX, r.maxY)), .close])
    }

    public static func ellipse(in r: Rect2) -> PathData {
        let k = 0.5522847498307936          // circle approximation with four cubics
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        return PathData(elements: [
            .move(Point(cx + rx, cy)),
            .cubic(Point(cx + rx, cy + k * ry), Point(cx + k * rx, cy + ry), Point(cx, cy + ry)),
            .cubic(Point(cx - k * rx, cy + ry), Point(cx - rx, cy + k * ry), Point(cx - rx, cy)),
            .cubic(Point(cx - rx, cy - k * ry), Point(cx - k * rx, cy - ry), Point(cx, cy - ry)),
            .cubic(Point(cx + k * rx, cy - ry), Point(cx + rx, cy - k * ry), Point(cx + rx, cy)),
            .close,
        ])
    }

    public init(cutPath: CutPath) {
        var e: [Element] = []
        for c in cutPath.contours {
            guard let first = c.segments.first else { continue }
            e.append(.move(first.p0))
            for s in c.segments { e.append(.cubic(s.p1, s.p2, s.p3)) }
            e.append(.close)
        }
        self.init(elements: e)
    }

    public func transformed(by t: Transform2D) -> PathData {
        PathData(elements: elements.map {
            switch $0 {
            case .move(let p): return .move(t.apply(p))
            case .line(let p): return .line(t.apply(p))
            case .cubic(let a, let b, let c): return .cubic(t.apply(a), t.apply(b), t.apply(c))
            case .close: return .close
            }
        })
    }

    /// Straight-line approximation: one polyline per subpath, with a flag telling whether it is closed.
    public func flattened(curveSteps: Int = 16) -> [(points: [Point], closed: Bool)] {
        var out: [(points: [Point], closed: Bool)] = []
        var current: [Point] = []
        var start: Point?
        var last = Point(0, 0)

        func finish(closed: Bool) {
            if current.count > 1 || (current.count == 1 && closed) { out.append((current, closed)) }
            current = []
        }
        for e in elements {
            switch e {
            case .move(let p):
                finish(closed: false)
                current = [p]; start = p; last = p
            case .line(let p):
                current.append(p); last = p
            case .cubic(let a, let b, let c):
                let seg = CubicBezier(last, a, b, c)
                for i in 1...curveSteps { current.append(seg.point(at: Double(i) / Double(curveSteps))) }
                last = c
            case .close:
                if let s = start, let l = current.last, (l - s).length < 1e-9 { current.removeLast() }
                finish(closed: true)
                if let s = start { last = s }
            }
        }
        finish(closed: false)
        return out
    }

    /// Straight-line approximation whose largest deviation from each curve is about `tolerance` millimetres.
    public func flattened(tolerance: Double) -> [(points: [Point], closed: Bool)] {
        var out: [(points: [Point], closed: Bool)] = []
        var current: [Point] = []
        var start: Point?
        var last = Point(0, 0)

        func finish(closed: Bool) {
            if current.count > 1 || (current.count == 1 && closed) { out.append((current, closed)) }
            current = []
        }
        for e in elements {
            switch e {
            case .move(let p):
                finish(closed: false)
                current = [p]; start = p; last = p
            case .line(let p):
                current.append(p); last = p
            case .cubic(let a, let b, let c):
                let dd0 = last - a * 2 + b, dd1 = a - b * 2 + c
                let m = max(dd0.length, dd1.length)
                let n = max(2, min(500, Int((0.75 * m / max(tolerance, 1e-6)).squareRoot().rounded(.up))))
                let seg = CubicBezier(last, a, b, c)
                for i in 1...n { current.append(seg.point(at: Double(i) / Double(n))) }
                last = c
            case .close:
                if let s = start, let l = current.last, (l - s).length < 1e-9 { current.removeLast() }
                finish(closed: true)
                if let s = start { last = s }
            }
        }
        finish(closed: false)
        return out
    }

    public var bounds: Rect2? {
        Rect2.bounding(flattened().flatMap { $0.points })
    }
}
