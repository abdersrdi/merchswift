import CutLine
import DocumentModel
import Export
import Foundation

public struct RefineOptions: Equatable {
    /// Softens the edge: the standard deviation, in pixels, of a blur applied to the cut-out's alpha. 0 keeps it hard.
    public var feather: Double
    /// Grows (positive) or shrinks (negative) the cut-out by this many pixels. Shrinking by one or two pixels removes
    /// the halo a rough cut-out leaves.
    public var shift: Double
    /// Turns the alpha into a clean on-or-off shape before shifting and softening, which removes stray faint pixels.
    public var harden: Bool
    /// Replaces the colour of edge pixels with colour from just inside, so the old background does not show as a fringe.
    public var defringe: Bool

    public init(feather: Double = 1, shift: Double = 0, harden: Bool = true, defringe: Bool = true) {
        self.feather = feather; self.shift = shift; self.harden = harden; self.defringe = defringe
    }
}

/// Tools that work on the shape of a picture (its alpha): cleaning a cut-out's edge, sticker borders, outlines, shadows.
public enum AlphaTools {
    // MARK: Refine

    public static func refine(_ image: RGBAImage, _ options: RefineOptions = RefineOptions()) -> RGBAImage {
        let w = image.width, h = image.height
        var alpha = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { alpha[i] = Float(image.pixels[i * 4 + 3]) / 255 }
        let originalAlpha = alpha

        if options.harden || options.shift != 0 {
            var mask = alpha.map { $0 >= 0.5 }
            if options.shift > 0 { mask = RasterOps.dilate(mask, width: w, height: h, radius: options.shift) }
            else if options.shift < 0 { mask = RasterOps.erode(mask, width: w, height: h, radius: -options.shift) }
            alpha = mask.map { $0 ? 1 : 0 }
        }
        if options.feather > 0 { alpha = Filters.gaussianBlur(alpha, width: w, height: h, sigma: options.feather) }

        var out = image
        if options.defringe {
            // Pixels whose colour can be trusted: solid before and after.
            var known = [Bool](repeating: false, count: w * h)
            for i in 0..<(w * h) { known[i] = originalAlpha[i] >= 0.98 && alpha[i] >= 0.98 }
            bleedColours(&out.pixels, known: &known, width: w, height: h, passes: max(3, Int(options.feather.rounded(.up)) * 2 + Int(abs(options.shift).rounded(.up)) + 2))
        }
        for i in 0..<(w * h) { out.pixels[i * 4 + 3] = UInt8(min(255, max(0, (alpha[i] * 255).rounded()))) }
        return out
    }

    /// Spreads colour outward from trusted pixels, one ring per pass, averaging the trusted neighbours.
    static func bleedColours(_ px: inout [UInt8], known: inout [Bool], width w: Int, height h: Int, passes: Int) {
        for _ in 0..<passes {
            var newly: [(Int, UInt8, UInt8, UInt8)] = []
            for y in 0..<h {
                for x in 0..<w where !known[y * w + x] {
                    var r = 0, g = 0, b = 0, n = 0
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx, ny = y + dy
                            if nx < 0 || ny < 0 || nx >= w || ny >= h || !known[ny * w + nx] { continue }
                            let o = (ny * w + nx) * 4
                            r += Int(px[o]); g += Int(px[o + 1]); b += Int(px[o + 2]); n += 1
                        }
                    }
                    if n > 0 { newly.append((y * w + x, UInt8(r / n), UInt8(g / n), UInt8(b / n))) }
                }
            }
            if newly.isEmpty { break }
            for (i, r, g, b) in newly { px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b; known[i] = true }
        }
    }

    // MARK: Border and outline

    /// A solid border around the artwork, like a sticker's white edge. The picture grows by the border and a margin of
    /// pixels; `padding` says how many pixels were added on each side so layers can be moved to match.
    /// The border follows the exact outline, so a thin tail or a hole in the middle gets its own border.
    public static func border(_ image: RGBAImage, thickness: Double, color: RGBA = .white) -> (image: RGBAImage, padding: Int) {
        guard thickness > 0 else { return (image, 0) }
        let pad = Int(thickness.rounded(.up)) + 2
        let w = image.width + 2 * pad, h = image.height + 2 * pad
        var sites = [Bool](repeating: false, count: w * h)
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixels[(y * image.width + x) * 4 + 3] >= 128 { sites[(y + pad) * w + x + pad] = true }
        }
        let d2 = RasterOps.squaredDistance(sites: sites, width: w, height: h)
        var borderAlpha = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { borderAlpha[i] = min(1, max(0, Float(thickness) + 0.5 - d2[i].squareRoot())) }
        return (composite(image, over: borderAlpha, colour: color, width: w, height: h, offsetX: pad, offsetY: pad), pad)
    }

    // MARK: Drop shadow

    /// A soft shadow under the artwork. The canvas grows to hold it; `padding` is the margin added on every side and the
    /// artwork sits at (padding, padding) in the result.
    public static func dropShadow(_ image: RGBAImage, dx: Double, dy: Double, blur: Double, color: RGBA = .black,
                                  opacity: Double = 0.5) -> (image: RGBAImage, padding: Int) {
        let pad = Int((blur * 3).rounded(.up)) + Int(max(abs(dx), abs(dy)).rounded(.up)) + 1
        let w = image.width + 2 * pad, h = image.height + 2 * pad
        var plane = [Float](repeating: 0, count: w * h)
        let sx = Int(dx.rounded()), sy = Int(dy.rounded())
        for y in 0..<image.height {
            for x in 0..<image.width {
                plane[(y + pad + sy) * w + x + pad + sx] = Float(image.pixels[(y * image.width + x) * 4 + 3]) / 255
            }
        }
        plane = Filters.gaussianBlur(plane, width: w, height: h, sigma: blur)
        for i in 0..<plane.count { plane[i] = min(1, max(0, plane[i] * Float(opacity) * Float(color.a))) }
        return (composite(image, over: plane, colour: color, width: w, height: h, offsetX: pad, offsetY: pad), pad)
    }

    // MARK: Compositing

    /// Puts `image` over a flat colour layer whose alpha is `under`, on a canvas of the given size.
    static func composite(_ image: RGBAImage, over under: [Float], colour: RGBA, width w: Int, height h: Int,
                          offsetX: Int, offsetY: Int) -> RGBAImage {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let cr = Float(colour.r), cg = Float(colour.g), cb = Float(colour.b)
        for y in 0..<h {
            for x in 0..<w {
                let ub = under[y * w + x]
                var fr: Float = 0, fg: Float = 0, fb: Float = 0, fa: Float = 0
                let ix = x - offsetX, iy = y - offsetY
                if ix >= 0, iy >= 0, ix < image.width, iy < image.height {
                    let o = (iy * image.width + ix) * 4
                    fa = Float(image.pixels[o + 3]) / 255
                    fr = Float(image.pixels[o]) / 255; fg = Float(image.pixels[o + 1]) / 255; fb = Float(image.pixels[o + 2]) / 255
                }
                let a = fa + ub * (1 - fa)
                let o = (y * w + x) * 4
                if a > 0.0001 {
                    let wf = fa / a, wu = ub * (1 - fa) / a
                    out[o] = UInt8(min(255, (fr * wf + cr * wu) * 255 + 0.5))
                    out[o + 1] = UInt8(min(255, (fg * wf + cg * wu) * 255 + 0.5))
                    out[o + 2] = UInt8(min(255, (fb * wf + cb * wu) * 255 + 0.5))
                }
                out[o + 3] = UInt8(min(255, a * 255 + 0.5))
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }
}
