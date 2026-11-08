import CutLine
import DocumentModel
import Foundation

/// Bends laid-out text along an arc or a path. The outline itself is bent point by point, so joined Arabic letters
/// stay joined and nothing depends on the script. Long straight edges are subdivided first so they curve too, and the
/// result is fitted back into Bezier curves.
public enum TextWarp {
    /// - Parameters:
    ///   - outline: glyph outlines laid out on a straight baseline, y down.
    ///   - blockWidth: the width of the laid-out block; an arc turns through its full width.
    ///   - baseline: the y of the first line's baseline.
    public static func apply(_ curve: TextCurve, to outline: PathData, blockWidth: Double, baseline: Double) -> PathData {
        let map: (Point) -> Point
        switch curve {
        case .arc(let degrees):
            let radians = abs(degrees) * .pi / 180
            guard radians > 1e-4, blockWidth > 1e-9 else { return outline }
            let radius = blockWidth / radians
            let s: Double = degrees > 0 ? 1 : -1
            let cx = blockWidth / 2, cy = baseline + s * radius
            map = { p in
                let phi = (p.x - cx) / radius
                let up = baseline - p.y
                let r = radius + s * up
                return Point(cx + r * sin(phi), cy - s * r * cos(phi))
            }
        case .path(let path, let offset):
            guard let track = Track(path: path) else { return outline }
            map = { p in
                let (point, tangent) = track.sample(at: offset + p.x)
                let normalUp = Point(tangent.y, -tangent.x)
                return point + normalUp * (baseline - p.y)
            }
        }

        let maxStep = 0.25
        var elements: [PathData.Element] = []
        for sub in outline.flattened(tolerance: 0.02) where sub.closed {
            let dense = densify(sub.points, maxStep: maxStep)
            let bent = dense.map(map)
            guard let contour = PolygonFit.fitClosed(bent, tolerance: 0.02, cornerAngleDegrees: 40),
                  let first = contour.segments.first else { continue }
            elements.append(.move(first.p0))
            for seg in contour.segments { elements.append(.cubic(seg.p1, seg.p2, seg.p3)) }
            elements.append(.close)
        }
        return PathData(elements: elements)
    }

    static func densify(_ pts: [Point], maxStep: Double) -> [Point] {
        var out: [Point] = []
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            out.append(a)
            let len = (b - a).length
            if len > maxStep {
                let n = Int((len / maxStep).rounded(.up))
                for k in 1..<n { out.append(a + (b - a) * (Double(k) / Double(n))) }
            }
        }
        return out
    }

    /// A path as a polyline with arc length, for placing points along it.
    struct Track {
        var points: [Point]
        var lengths: [Double]       // cumulative, lengths[0] = 0

        init?(path: PathData) {
            guard let sub = path.flattened(tolerance: 0.02).first, sub.points.count >= 2 else { return nil }
            var pts = sub.points
            if sub.closed, let f = pts.first { pts.append(f) }
            var cum = [0.0]
            for i in 1..<pts.count { cum.append(cum[i - 1] + (pts[i] - pts[i - 1]).length) }
            guard let total = cum.last, total > 1e-9 else { return nil }
            points = pts; lengths = cum
        }

        var total: Double { lengths.last ?? 0 }

        /// The point and unit direction at distance `s` along the path. Beyond either end the path carries on
        /// in a straight line, so text that overshoots keeps going instead of piling up.
        func sample(at s: Double) -> (Point, Point) {
            if s <= 0 {
                let t = (points[1] - points[0]).normalized()
                return (points[0] + t * s, t)
            }
            if s >= total {
                let n = points.count
                let t = (points[n - 1] - points[n - 2]).normalized()
                return (points[n - 1] + t * (s - total), t)
            }
            var lo = 0, hi = lengths.count - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if lengths[m] <= s { lo = m } else { hi = m } }
            let seg = lengths[hi] - lengths[lo]
            let f = seg > 1e-12 ? (s - lengths[lo]) / seg : 0
            let t = (points[hi] - points[lo]).normalized()
            return (points[lo] + (points[hi] - points[lo]) * f, t)
        }
    }
}
