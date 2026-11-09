import Foundation

/// Raster helpers for the cut line: exact distance transform, hole filling, component filtering, blur.
public enum RasterOps {
    static let inf: Float = 1e20

    /// Squared Euclidean distance from every pixel to the nearest pixel where `sites` is true
    /// (Felzenszwalb and Huttenlocher, exact, linear time).
    public static func squaredDistance(sites: [Bool], width: Int, height: Int) -> [Float] {
        var f = [Float](repeating: 0, count: width * height)
        for i in 0..<f.count { f[i] = sites[i] ? 0 : inf }

        var column = [Float](repeating: 0, count: height)
        for x in 0..<width {
            for y in 0..<height { column[y] = f[y * width + x] }
            let d = dt1(column)
            for y in 0..<height { f[y * width + x] = d[y] }
        }
        var row = [Float](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width { row[x] = f[y * width + x] }
            let d = dt1(row)
            for x in 0..<width { f[y * width + x] = d[x] }
        }
        return f
    }

    private static func dt1(_ f: [Float]) -> [Float] {
        let n = f.count
        var d = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Float](repeating: 0, count: n + 1)
        var k = 0
        v[0] = 0
        z[0] = -inf
        z[1] = inf
        if n == 1 { return [f[0]] }
        for q in 1..<n {
            var s: Float = 0
            while true {
                let p = v[k]
                s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * q - 2 * p)
                if s <= z[k] && k > 0 { k -= 1 } else { break }
            }
            k += 1
            v[k] = q
            z[k] = s
            z[k + 1] = inf
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let dq = Float(q - v[k])
            d[q] = dq * dq + f[v[k]]
        }
        return d
    }

    /// Grows the true pixels of `mask` by `radius` pixels (round structuring element).
    public static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Double) -> [Bool] {
        if radius <= 0 { return mask }
        let d2 = squaredDistance(sites: mask, width: width, height: height)
        let r2 = Float(radius * radius)
        return d2.map { $0 <= r2 }
    }

    /// Shrinks the true pixels of `mask` by `radius` pixels.
    public static func erode(_ mask: [Bool], width: Int, height: Int, radius: Double) -> [Bool] {
        if radius <= 0 { return mask }
        let d2 = squaredDistance(sites: mask.map { !$0 }, width: width, height: height)
        let r2 = Float(radius * radius)
        return d2.map { $0 > r2 }
    }

    /// Makes every region that is not connected to the border true, so cut lines ignore interior holes.
    static func fillHoles(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        func push(_ i: Int) {
            if !mask[i] && !outside[i] { outside[i] = true; stack.append(i) }
        }
        for x in 0..<width { push(x); push((height - 1) * width + x) }
        for y in 0..<height { push(y * width); push(y * width + width - 1) }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            if x > 0 { push(i - 1) }
            if x < width - 1 { push(i + 1) }
            if y > 0 { push(i - width) }
            if y < height - 1 { push(i + width) }
        }
        return outside.map { !$0 }
    }

    /// Keeps only connected components whose area is at least `fraction` of the largest one.
    static func dropSmallComponents(_ mask: [Bool], width: Int, height: Int, fraction: Double) -> [Bool] {
        var label = [Int32](repeating: 0, count: mask.count)
        var areas: [Int] = [0]
        var next: Int32 = 1
        var stack: [Int] = []
        for start in 0..<mask.count where mask[start] && label[start] == 0 {
            label[start] = next
            stack.append(start)
            var area = 0
            while let i = stack.popLast() {
                area += 1
                let x = i % width, y = i / width
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= width || ny >= height { continue }
                        let j = ny * width + nx
                        if mask[j] && label[j] == 0 { label[j] = next; stack.append(j) }
                    }
                }
            }
            areas.append(area)
            next += 1
        }
        guard let largest = areas.max(), largest > 0 else { return mask }
        let keepMin = Int((Double(largest) * fraction).rounded(.up))
        return label.map { $0 > 0 && areas[Int($0)] >= keepMin }
    }

    /// Gaussian blur of a 0/1 mask (separable, clamped edges). Returns floats in 0...1.
    static func blur(_ mask: [Bool], width: Int, height: Int, sigma: Double) -> [Float] {
        let src = mask.map { $0 ? Float(1) : Float(0) }
        if sigma <= 0.01 { return src }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Float](repeating: 0, count: radius * 2 + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = Float(exp(-Double(i * i) / (2 * sigma * sigma)))
            kernel[i + radius] = v
            sum += v
        }
        for i in 0..<kernel.count { kernel[i] /= sum }

        var tmp = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for k in -radius...radius {
                    let xx = min(max(x + k, 0), width - 1)
                    acc += src[y * width + xx] * kernel[k + radius]
                }
                tmp[y * width + x] = acc
            }
        }
        var out = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for k in -radius...radius {
                    let yy = min(max(y + k, 0), height - 1)
                    acc += tmp[yy * width + x] * kernel[k + radius]
                }
                out[y * width + x] = acc
            }
        }
        return out
    }
}
