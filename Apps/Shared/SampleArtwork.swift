import CoreGraphics
import Export
import Foundation

/// A procedural sticker used by the proof screen: a red five-lobed shape with a white border.
enum SampleArtwork {
    static func make(size: Int) -> RGBAImage {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let c = Double(size) / 2
        let base = Double(size) * 0.30, wave = Double(size) * 0.08, border = Double(size) * 0.035
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
                let r = (dx * dx + dy * dy).squareRoot()
                let edge = base + wave * cos(5 * atan2(dy, dx))
                guard r <= edge else { continue }
                let inner = r <= edge - border
                let i = (y * size + x) * 4
                px[i] = inner ? 214 : 255
                px[i + 1] = inner ? 40 : 255
                px[i + 2] = inner ? 52 : 255
                px[i + 3] = 255
            }
        }
        return RGBAImage(width: size, height: size, pixels: px)
    }

    static func cgImage(_ image: RGBAImage) -> CGImage? {
        let data = Data(image.pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
