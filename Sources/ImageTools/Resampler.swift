import Export
import Foundation

/// High-quality resizing. Colour is resampled premultiplied by alpha, so the edge of a cut-out never picks up a dark or
/// light fringe from the transparent pixels around it.
public enum Resampler {
    /// Lanczos resampling to an exact size. Upscaling keeps edges crisp; downscaling widens the filter so it averages
    /// instead of skipping pixels.
    public static func lanczos(_ image: RGBAImage, toWidth outW: Int, height outH: Int, lobes: Int = 3) -> RGBAImage {
        precondition(outW > 0 && outH > 0, "target size must be positive")
        let inW = image.width, inH = image.height
        if inW == outW && inH == outH { return image }

        let hx = taps(inSize: inW, outSize: outW, lobes: lobes)
        let vy = taps(inSize: inH, outSize: outH, lobes: lobes)

        // Premultiplied source as Float rows is built one row at a time; the middle result is kept as 16-bit
        // values (premultiplied, 0...65535) so an 8000 pixel wide picture does not need gigabytes.
        var mid = [UInt16](repeating: 0, count: outW * inH * 4)
        var row = [Float](repeating: 0, count: inW * 4)
        for y in 0..<inH {
            for x in 0..<inW {
                let i = (y * inW + x) * 4
                let a = Float(image.pixels[i + 3]) / 255
                row[x * 4] = Float(image.pixels[i]) / 255 * a
                row[x * 4 + 1] = Float(image.pixels[i + 1]) / 255 * a
                row[x * 4 + 2] = Float(image.pixels[i + 2]) / 255 * a
                row[x * 4 + 3] = a
            }
            for ox in 0..<outW {
                let t = hx[ox]
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                for k in 0..<t.weights.count {
                    let j = (t.start + k) * 4, w = t.weights[k]
                    r += row[j] * w; g += row[j + 1] * w; b += row[j + 2] * w; a += row[j + 3] * w
                }
                let o = (y * outW + ox) * 4
                mid[o] = quant(r); mid[o + 1] = quant(g); mid[o + 2] = quant(b); mid[o + 3] = quant(a)
            }
        }

        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        var col = [Float](repeating: 0, count: 4)
        for oy in 0..<outH {
            let t = vy[oy]
            for x in 0..<outW {
                col[0] = 0; col[1] = 0; col[2] = 0; col[3] = 0
                for k in 0..<t.weights.count {
                    let j = ((t.start + k) * outW + x) * 4, w = t.weights[k]
                    col[0] += Float(mid[j]) * w; col[1] += Float(mid[j + 1]) * w
                    col[2] += Float(mid[j + 2]) * w; col[3] += Float(mid[j + 3]) * w
                }
                let a = min(max(col[3] / 65535, 0), 1)
                let o = (oy * outW + x) * 4
                if a > 0.0001 {
                    for c in 0..<3 { out[o + c] = UInt8(min(255, max(0, (col[c] / 65535 / a * 255).rounded()))) }
                }
                out[o + 3] = UInt8((a * 255).rounded())
            }
        }
        return RGBAImage(width: outW, height: outH, pixels: out)
    }

    /// Scales by a factor, rounding the size.
    public static func lanczos(_ image: RGBAImage, scale: Double) -> RGBAImage {
        lanczos(image, toWidth: max(1, Int((Double(image.width) * scale).rounded())), height: max(1, Int((Double(image.height) * scale).rounded())))
    }

    private static func quant(_ v: Float) -> UInt16 { UInt16(min(65535, max(0, (v * 65535).rounded()))) }

    struct Taps { var start: Int; var weights: [Float] }

    /// For every output position, the run of input positions that feed it and their weights (summing to 1).
    static func taps(inSize: Int, outSize: Int, lobes: Int) -> [Taps] {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(1, scale)               // widen the filter when shrinking
        let support = Double(lobes) * filterScale
        var out: [Taps] = []
        out.reserveCapacity(outSize)
        for o in 0..<outSize {
            let centre = (Double(o) + 0.5) * scale - 0.5
            let lo = max(0, Int((centre - support).rounded(.up))), hi = min(inSize - 1, Int((centre + support).rounded(.down)))
            var w: [Float] = []
            var sum = 0.0
            var weights: [Double] = []
            if hi < lo {
                let nearest = min(max(Int(centre.rounded()), 0), inSize - 1)
                out.append(Taps(start: nearest, weights: [1]))
                continue
            }
            for i in lo...hi {
                let v = kernel((Double(i) - centre) / filterScale, lobes: Double(lobes))
                weights.append(v); sum += v
            }
            if abs(sum) < 1e-12 { weights = weights.map { _ in 1.0 / Double(weights.count) }; sum = 1 }
            w = weights.map { Float($0 / sum) }
            out.append(Taps(start: lo, weights: w))
        }
        return out
    }

    static func kernel(_ x: Double, lobes a: Double) -> Double {
        if x == 0 { return 1 }
        if abs(x) >= a { return 0 }
        let px = Double.pi * x
        return a * sin(px) * sin(px / a) / (px * px)
    }
}
