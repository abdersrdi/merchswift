import Foundation

/// Least-squares cubic Bezier fitting (Philip J. Schneider, "An Algorithm for Automatically Fitting
/// Digitized Curves", Graphics Gems, 1990), applied to a closed outline.
enum BezierFit {
    /// Fits a closed polyline. `tolerance` is the largest allowed distance between the curve and the points.
    static func fitClosed(_ input: [Point], tolerance: Double, cornerAngleDegrees: Double = 55) -> Contour? {
        var pts: [Point] = []
        for p in input where pts.last.map({ ($0 - p).length > 1e-9 }) ?? true { pts.append(p) }
        if let f = pts.first, let l = pts.last, (f - l).length < 1e-9 { pts.removeLast() }
        let n = pts.count
        guard n >= 4 else { return nil }

        let corners = findCorners(pts, angle: cornerAngleDegrees)
        var splitIndices = corners
        if splitIndices.isEmpty {
            splitIndices = [0, n / 2]
        } else if splitIndices.count == 1 {
            splitIndices.append((splitIndices[0] + n / 2) % n)
        }
        splitIndices.sort()

        func tangentAt(_ i: Int, corner: Bool, forward: Bool) -> Point {
            let prev = pts[(i - 1 + n) % n], next = pts[(i + 1) % n], here = pts[i]
            if corner {
                // One-sided tangent, pointing into the section that starts or ends here.
                let look = 3
                if forward { return (pts[(i + look) % n] - here).normalized() }
                return (pts[(i - look + n) % n] - here).normalized()
            }
            let t = (next - prev).normalized()
            return forward ? t : t * -1
        }

        var segments: [CubicBezier] = []
        for k in 0..<splitIndices.count {
            let a = splitIndices[k]
            let b = splitIndices[(k + 1) % splitIndices.count]
            var section: [Point] = []
            var i = a
            while true {
                section.append(pts[i])
                if i == b && section.count > 1 { break }
                i = (i + 1) % n
                if section.count > n + 1 { break }
            }
            guard section.count >= 2 else { continue }
            let cornerA = corners.contains(a), cornerB = corners.contains(b)
            let t1 = tangentAt(a, corner: cornerA, forward: true)
            let t2 = tangentAt(b, corner: cornerB, forward: false)
            segments.append(contentsOf: fitCurve(section, t1, t2, error: tolerance))
        }
        return segments.isEmpty ? nil : Contour(segments: segments)
    }

    static func findCorners(_ pts: [Point], angle: Double) -> [Int] {
        let n = pts.count
        let k = 4
        guard n > 3 * k else { return [] }
        var turn = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = pts[i] - pts[(i - k + n) % n]
            let b = pts[(i + k) % n] - pts[i]
            let la = a.length, lb = b.length
            if la < 1e-9 || lb < 1e-9 { continue }
            let c = max(-1, min(1, a.dot(b) / (la * lb)))
            turn[i] = acos(c) * 180 / .pi
        }
        var corners: [Int] = []
        for i in 0..<n where turn[i] > angle {
            var isMax = true
            for d in -k...k where d != 0 {
                let j = (i + d + n) % n
                if turn[j] > turn[i] || (turn[j] == turn[i] && d < 0) { isMax = false; break }
            }
            if isMax { corners.append(i) }
        }
        return corners
    }

    // MARK: Schneider

    static func fitCurve(_ d: [Point], _ tHat1: Point, _ tHat2: Point, error: Double) -> [CubicBezier] {
        let n = d.count
        if n == 2 {
            let dist = (d[1] - d[0]).length / 3
            return [CubicBezier(d[0], d[0] + tHat1 * dist, d[1] + tHat2 * dist, d[1])]
        }
        var u = chordLengthParameterize(d)
        var bez = generateBezier(d, u, tHat1, tHat2)
        var (maxErr, split) = computeMaxError(d, bez, u)
        if maxErr < error { return [bez] }

        if maxErr < error * 16 {
            for _ in 0..<6 {
                u = reparameterize(d, u, bez)
                bez = generateBezier(d, u, tHat1, tHat2)
                (maxErr, split) = computeMaxError(d, bez, u)
                if maxErr < error { return [bez] }
            }
        }

        split = min(max(split, 1), n - 2)
        var tCenter = (d[split - 1] - d[split + 1]).normalized()
        if tCenter.length == 0 { tCenter = (d[split - 1] - d[split]).normalized() }
        let left = fitCurve(Array(d[0...split]), tHat1, tCenter, error: error)
        let right = fitCurve(Array(d[split...]), tCenter * -1, tHat2, error: error)
        return left + right
    }

    static func generateBezier(_ d: [Point], _ u: [Double], _ tHat1: Point, _ tHat2: Point) -> CubicBezier {
        let n = d.count
        let first = d[0], last = d[n - 1]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for i in 0..<n {
            let t = u[i], mt = 1 - t
            let b0 = mt * mt * mt, b1 = 3 * mt * mt * t, b2 = 3 * mt * t * t, b3 = t * t * t
            let a1 = tHat1 * b1, a2 = tHat2 * b2
            c00 += a1.dot(a1)
            c01 += a1.dot(a2)
            c11 += a2.dot(a2)
            let tmp = d[i] - (first * (b0 + b1) + last * (b2 + b3))
            x0 += a1.dot(tmp)
            x1 += a2.dot(tmp)
        }
        let det = c00 * c11 - c01 * c01
        var alpha1 = 0.0, alpha2 = 0.0
        if abs(det) > 1e-12 {
            alpha1 = (x0 * c11 - x1 * c01) / det
            alpha2 = (c00 * x1 - c01 * x0) / det
        }
        let segLength = (last - first).length
        let eps = 1e-6 * segLength
        if alpha1 < eps || alpha2 < eps {
            let dist = segLength / 3
            return CubicBezier(first, first + tHat1 * dist, last + tHat2 * dist, last)
        }
        return CubicBezier(first, first + tHat1 * alpha1, last + tHat2 * alpha2, last)
    }

    static func reparameterize(_ d: [Point], _ u: [Double], _ b: CubicBezier) -> [Double] {
        var out = u
        for i in 0..<d.count { out[i] = newtonRaphson(b, d[i], u[i]) }
        return out
    }

    static func newtonRaphson(_ b: CubicBezier, _ p: Point, _ u: Double) -> Double {
        let q = b.point(at: u)
        // First and second derivative control points.
        let q1 = [(b.p1 - b.p0) * 3, (b.p2 - b.p1) * 3, (b.p3 - b.p2) * 3]
        let q2 = [(q1[1] - q1[0]) * 2, (q1[2] - q1[1]) * 2]
        let mu = 1 - u
        let d1 = q1[0] * (mu * mu) + q1[1] * (2 * mu * u) + q1[2] * (u * u)
        let d2 = q2[0] * mu + q2[1] * u
        let diff = q - p
        let numerator = diff.dot(d1)
        let denominator = d1.dot(d1) + diff.dot(d2)
        if abs(denominator) < 1e-12 { return u }
        return min(1, max(0, u - numerator / denominator))
    }

    static func chordLengthParameterize(_ d: [Point]) -> [Double] {
        var u = [Double](repeating: 0, count: d.count)
        for i in 1..<d.count { u[i] = u[i - 1] + (d[i] - d[i - 1]).length }
        let total = u[d.count - 1]
        if total > 0 { for i in 1..<d.count { u[i] /= total } }
        return u
    }

    static func computeMaxError(_ d: [Point], _ b: CubicBezier, _ u: [Double]) -> (Double, Int) {
        var maxDist = 0.0
        var split = d.count / 2
        for i in 1..<(d.count - 1) {
            let dist = (b.point(at: u[i]) - d[i]).length
            if dist >= maxDist { maxDist = dist; split = i }
        }
        return (maxDist, split)
    }
}
