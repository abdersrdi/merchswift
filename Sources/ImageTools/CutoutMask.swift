import Foundation
import Export

/// Turns a subject mask (0...1 per pixel, row 0 at the top) into a cut-out. Plain Swift so it is tested on every platform;
/// the Apple-only Vision step in `VisionCutout` supplies the mask.
public enum CutoutMask {
    /// Multiplies the picture's alpha by the mask. Colour is left alone (the pixels are not premultiplied).
    public static func apply(_ mask: [Float], to image: RGBAImage) -> RGBAImage {
        precondition(mask.count == image.width * image.height, "mask does not match the picture")
        var out = image
        for i in 0..<mask.count {
            let m = min(1, max(0, mask[i]))
            let a = Float(image.pixels[i * 4 + 3]) * m
            out.pixels[i * 4 + 3] = UInt8(min(255, max(0, a.rounded())))
        }
        return out
    }

    /// Scales a mask of another size to the picture's size (bilinear), for masks the system returns at reduced resolution.
    public static func resize(_ mask: [Float], width: Int, height: Int, toWidth w: Int, toHeight h: Int) -> [Float] {
        if width == w && height == h { return mask }
        var out = [Float](repeating: 0, count: w * h)
        guard width > 0, height > 0 else { return out }
        for y in 0..<h {
            let fy = (Float(y) + 0.5) * Float(height) / Float(h) - 0.5
            let y0 = max(0, min(height - 1, Int(fy.rounded(.down)))), y1 = min(height - 1, y0 + 1)
            let ty = min(1, max(0, fy - Float(y0)))
            for x in 0..<w {
                let fx = (Float(x) + 0.5) * Float(width) / Float(w) - 0.5
                let x0 = max(0, min(width - 1, Int(fx.rounded(.down)))), x1 = min(width - 1, x0 + 1)
                let tx = min(1, max(0, fx - Float(x0)))
                let top = mask[y0 * width + x0] * (1 - tx) + mask[y0 * width + x1] * tx
                let bottom = mask[y1 * width + x0] * (1 - tx) + mask[y1 * width + x1] * tx
                out[y * w + x] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }
}
