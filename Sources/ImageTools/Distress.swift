import Export
import Foundation

public struct DistressOptions: Equatable {
    /// The fraction of the artwork worn away, 0 (none) to 1 (all).
    public var amount: Double
    /// Size of the worn patches in pixels. Small gives fine scuffs, large gives big cracks.
    public var scale: Double
    /// Detail: how many layers of finer wear are added on top of the broad patches (1 to 6).
    public var roughness: Int
    /// The same seed always gives the same wear, so an export matches the preview.
    public var seed: UInt64
    /// How soft the edge of each worn patch is, in noise units (0.01 is crisp, 0.1 is soft).
    public var softness: Double

    public init(amount: Double = 0.25, scale: Double = 24, roughness: Int = 4, seed: UInt64 = 1, softness: Double = 0.03) {
        self.amount = amount; self.scale = scale; self.roughness = roughness; self.seed = seed; self.softness = softness
    }
}

/// The worn, cracked-ink look of a vintage print: a noise pattern erases part of the artwork. Colours are untouched; only
/// alpha is reduced, so the garment shows through the wear.
public enum Distress {
    public static func apply(_ image: RGBAImage, _ options: DistressOptions = DistressOptions()) -> RGBAImage {
        let w = image.width, h = image.height
        guard options.amount > 0, w > 0, h > 0 else { return image }
        if options.amount >= 1 {
            var gone = image
            for i in 0..<(w * h) { gone.pixels[i * 4 + 3] = 0 }
            return gone
        }
        let field = noiseField(width: w, height: h, scale: max(options.scale, 1), octaves: min(max(options.roughness, 1), 6), seed: options.seed)

        // Choose the threshold so that exactly `amount` of the area falls below it.
        var histogram = [Int](repeating: 0, count: 1024)
        for v in field { histogram[min(1023, Int(v * 1024))] += 1 }
        let target = Int(Double(field.count) * min(max(options.amount, 0), 1))
        var running = 0, bin = 0
        while bin < 1023 && running + histogram[bin] < target { running += histogram[bin]; bin += 1 }
        let threshold = Float(bin) / 1024 + Float(max(target - running, 0)) / Float(max(histogram[bin], 1)) / 1024

        var out = image
        let soft = Float(max(options.softness, 0.001))
        for i in 0..<(w * h) {
            let keep = min(1, max(0, (field[i] - threshold) / soft + 0.5))
            out.pixels[i * 4 + 3] = UInt8((Float(image.pixels[i * 4 + 3]) * keep).rounded())
        }
        return out
    }

    /// Fractal value noise in 0...1: several octaves of smooth random lattice values, each finer and fainter.
    static func noiseField(width w: Int, height h: Int, scale: Double, octaves: Int, seed: UInt64) -> [Float] {
        var field = [Float](repeating: 0, count: w * h)
        var amplitude: Float = 1, total: Float = 0
        var frequency = 1.0 / scale
        for o in 0..<octaves {
            let octaveSeed = seed &+ UInt64(o) &* 0x9E3779B97F4A7C15
            for y in 0..<h {
                for x in 0..<w {
                    field[y * w + x] += amplitude * valueNoise(Double(x) * frequency, Double(y) * frequency, seed: octaveSeed)
                }
            }
            total += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        let lo = field.min() ?? 0, hi = field.max() ?? 1
        let range = max(hi - lo, 1e-6)
        for i in 0..<field.count { field[i] = min(0.99999, (field[i] - lo) / range) }
        _ = total
        return field
    }

    static func valueNoise(_ x: Double, _ y: Double, seed: UInt64) -> Float {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = lattice(x0, y0, seed), b = lattice(x0 + 1, y0, seed), c = lattice(x0, y0 + 1, seed), d = lattice(x0 + 1, y0 + 1, seed)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    static func lattice(_ x: Int, _ y: Int, _ seed: UInt64) -> Float {
        var h = seed ^ (UInt64(bitPattern: Int64(x)) &* 0x9E3779B185EBCA87) ^ (UInt64(bitPattern: Int64(y)) &* 0xC2B2AE3D27D4EB4F)
        h ^= h >> 33; h = h &* 0xFF51AFD7ED558CCD; h ^= h >> 33; h = h &* 0xC4CEB9FE1A85EC53; h ^= h >> 33
        return Float(h & 0xFFFFFF) / Float(0x1000000)
    }
}
