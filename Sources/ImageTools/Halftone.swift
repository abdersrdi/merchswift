import DocumentModel
import Export
import Foundation

public struct HalftoneOptions: Equatable {
    /// Distance between dot centres, in pixels.
    public var cell: Double
    /// Rotation of the dot grid in degrees. 45 is the classic screen.
    public var angle: Double
    /// One ink for every dot; nil gives each dot the colour of the picture under it.
    public var ink: RGBA?
    /// False makes dark parts big dots (ink on a light shirt); true makes light parts big dots (light ink on a dark shirt).
    public var invert: Bool
    /// Multiplies how big the dots get: above 1 prints heavier, below 1 lighter.
    public var gain: Double

    public init(cell: Double = 12, angle: Double = 45, ink: RGBA? = .black, invert: Bool = false, gain: Double = 1) {
        self.cell = cell; self.angle = angle; self.ink = ink; self.invert = invert; self.gain = gain
    }
}

/// The dot-screen look used on T-shirts: tone becomes the size of round dots on a regular grid, on a transparent
/// background, so the garment shows through between them.
public enum Halftone {
    public static func apply(_ image: RGBAImage, _ options: HalftoneOptions = HalftoneOptions()) -> RGBAImage {
        let w = image.width, h = image.height
        let cell = max(options.cell, 2)

        // Tone per pixel (0 none ... 1 full ink), smoothed to a dot's size so a dot reads the area it stands for.
        var tone = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let a = Float(image.pixels[i * 4 + 3]) / 255
            let luma = (0.2126 * Float(image.pixels[i * 4]) + 0.7152 * Float(image.pixels[i * 4 + 1]) + 0.0722 * Float(image.pixels[i * 4 + 2])) / 255
            tone[i] = (options.invert ? luma : 1 - luma) * a
        }
        tone = Filters.gaussianBlur(tone, width: w, height: h, sigma: cell / 3)

        let theta = options.angle * .pi / 180
        let c = cos(theta), s = sin(theta)
        var out = [UInt8](repeating: 0, count: w * h * 4)

        for y in 0..<h {
            for x in 0..<w {
                // Position in the rotated grid, in cells.
                let u = (Double(x) + 0.5) * c + (Double(y) + 0.5) * s
                let v = -(Double(x) + 0.5) * s + (Double(y) + 0.5) * c
                let iu = Int((u / cell).rounded(.down)), iv = Int((v / cell).rounded(.down))
                var best: Float = 0
                var bestX = 0, bestY = 0
                for dj in -1...1 {
                    for di in -1...1 {
                        let cu = (Double(iu + di) + 0.5) * cell, cv = (Double(iv + dj) + 0.5) * cell
                        // Back to the image, to read the tone at the dot's centre.
                        let cx = cu * c - cv * s, cy = cu * s + cv * c
                        let sx = min(max(Int(cx.rounded(.down)), 0), w - 1), sy = min(max(Int(cy.rounded(.down)), 0), h - 1)
                        let t = min(1, max(0, Float(tone[sy * w + sx]) * Float(options.gain)))
                        if t <= 0.002 { continue }
                        let r = radius(forTone: Double(t), cell: cell)
                        let d = ((u - cu) * (u - cu) + (v - cv) * (v - cv)).squareRoot()
                        let cover = Float(min(1, max(0, r - d + 0.5)))
                        if cover > best { best = cover; bestX = sx; bestY = sy }
                    }
                }
                guard best > 0 else { continue }
                let o = (y * w + x) * 4
                if let ink = options.ink {
                    out[o] = UInt8((ink.r * 255).rounded()); out[o + 1] = UInt8((ink.g * 255).rounded()); out[o + 2] = UInt8((ink.b * 255).rounded())
                    out[o + 3] = UInt8(min(255, (Double(best) * ink.a * 255).rounded()))
                } else {
                    let src = (bestY * w + bestX) * 4
                    out[o] = image.pixels[src]; out[o + 1] = image.pixels[src + 1]; out[o + 2] = image.pixels[src + 2]
                    out[o + 3] = UInt8(min(255, (Double(best) * 255).rounded()))
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }

    /// Dot radius for a tone: the dot's area is the tone times the cell's area up to where neighbouring dots meet, and
    /// then the dots swell to fill the cell completely at full tone.
    static func radius(forTone t: Double, cell: Double) -> Double {
        let meet = Double.pi / 4
        if t <= meet { return cell * (t / .pi).squareRoot() }
        let r0 = cell * 0.5, r1 = cell * 0.70711
        return r0 + (r1 - r0) * min(1, (t - meet) / (1 - meet))
    }
}
