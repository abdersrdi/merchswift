import Export
import Foundation

/// Makes a low-resolution picture bigger so it reaches a product's print resolution.
///
/// This is the plain, always-available method: Lanczos resampling (colour premultiplied, so cut-out edges stay clean) followed by
/// a light sharpening pass to win back some of the crispness enlarging takes away. It cannot invent detail. A learned
/// model (Core ML) can do better on photos and will plug in behind the same call later.
public enum Upscaler {
    /// The most pixels allowed on the longest side, so one picture cannot use all of the device's memory.
    public static let maxSide = 8192

    /// The enlargement needed to print at `targetDPI`, given how many dots per inch the picture has now. 1 means none.
    public static func factor(effectiveDPI: Double, targetDPI: Double) -> Double {
        guard effectiveDPI > 0, targetDPI > effectiveDPI else { return 1 }
        return targetDPI / effectiveDPI
    }

    /// Enlarges by `factor` (at least 1). The result is limited to `maxSide`, so it may be smaller than asked for; the new
    /// dimensions tell what was done.
    public static func upscale(_ image: RGBAImage, factor: Double, sharpen: Bool = true) -> RGBAImage {
        guard factor > 1.0001, image.width > 0, image.height > 0 else { return image }
        let longest = Double(max(image.width, image.height))
        let f = min(factor, Double(maxSide) / longest)
        guard f > 1.0001 else { return image }
        let w = max(1, Int((Double(image.width) * f).rounded())), h = max(1, Int((Double(image.height) * f).rounded()))
        let big = Resampler.lanczos(image, toWidth: w, height: h)
        // Sharpen in proportion to the enlargement: a 2x picture needs more than a 1.1x one, up to a limit.
        guard sharpen else { return big }
        let amount = min(0.7, 0.25 + 0.15 * (f - 1))
        return Filters.unsharpMask(big, radius: max(0.8, f * 0.6), amount: amount)
    }
}
