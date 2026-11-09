import Export
import Foundation

/// Separable Gaussian blur and the filters built on it.
public enum Filters {
    /// Blurs one plane of values with a Gaussian of the given standard deviation (in pixels). Edges repeat.
    public static func gaussianBlur(_ plane: [Float], width: Int, height: Int, sigma: Double) -> [Float] {
        guard sigma > 0.05, width > 0, height > 0 else { return plane }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Float](repeating: 0, count: radius * 2 + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = Float(exp(-Double(i * i) / (2 * sigma * sigma)))
            kernel[i + radius] = v; sum += v
        }
        for i in 0..<kernel.count { kernel[i] /= sum }

        var tmp = [Float](repeating: 0, count: plane.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var acc: Float = 0
                for k in -radius...radius { acc += plane[row + min(max(x + k, 0), width - 1)] * kernel[k + radius] }
                tmp[row + x] = acc
            }
        }
        var out = [Float](repeating: 0, count: plane.count)
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for k in -radius...radius { acc += tmp[min(max(y + k, 0), height - 1) * width + x] * kernel[k + radius] }
                out[y * width + x] = acc
            }
        }
        return out
    }

    /// Sharpens by adding back the difference from a blurred copy (an unsharp mask). `amount` of 0.5 to 1.5 is typical;
    /// differences below `threshold` (0...1) are left alone so noise and smooth gradients stay quiet.
    /// Works on colour only, weighted by alpha, so transparent edges are untouched.
    public static func unsharpMask(_ image: RGBAImage, radius: Double, amount: Double, threshold: Double = 0) -> RGBAImage {
        let w = image.width, h = image.height
        var out = image
        for c in 0..<3 {
            var plane = [Float](repeating: 0, count: w * h)
            for i in 0..<(w * h) { plane[i] = Float(image.pixels[i * 4 + c]) / 255 }
            let blurred = gaussianBlur(plane, width: w, height: h, sigma: radius)
            for i in 0..<(w * h) {
                let diff = plane[i] - blurred[i]
                if abs(diff) < Float(threshold) { continue }
                let v = plane[i] + diff * Float(amount)
                out.pixels[i * 4 + c] = UInt8(min(255, max(0, (v * 255).rounded())))
            }
        }
        return out
    }

    /// A faded, warm, print-from-an-old-shirt look: blacks lifted, colour pulled toward grey, a little warmth.
    /// `fade` and `warmth` run from 0 (off) to 1 (strong). Alpha is untouched.
    public static func vintageTone(_ image: RGBAImage, fade: Double, warmth: Double) -> RGBAImage {
        var out = image
        let lift = Float(fade) * 0.12, desat = Float(fade) * 0.35, warm = Float(warmth)
        for i in 0..<(image.width * image.height) {
            var r = Float(image.pixels[i * 4]) / 255, g = Float(image.pixels[i * 4 + 1]) / 255, b = Float(image.pixels[i * 4 + 2]) / 255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r += (luma - r) * desat; g += (luma - g) * desat; b += (luma - b) * desat
            r = r * (1 - lift) + lift; g = g * (1 - lift) + lift; b = b * (1 - lift * 0.8) + lift * 0.8
            r += 0.05 * warm; g += 0.015 * warm; b -= 0.06 * warm
            out.pixels[i * 4] = UInt8(min(255, max(0, (r * 255).rounded())))
            out.pixels[i * 4 + 1] = UInt8(min(255, max(0, (g * 255).rounded())))
            out.pixels[i * 4 + 2] = UInt8(min(255, max(0, (b * 255).rounded())))
        }
        return out
    }
}
