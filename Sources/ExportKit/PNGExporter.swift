#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import CutLine
import DocumentModel
import Foundation
import ImageIO
import Renderer

public enum PNGExportError: Error, CustomStringConvertible {
    case tooLarge(width: Int, height: Int)
    case encodingFailed

    public var description: String {
        switch self {
        case .tooLarge(let w, let h): return "The image would be \(w) x \(h) pixels, which is more than this device can export."
        case .encodingFailed: return "The PNG could not be written."
        }
    }
}

/// Writes a design as a PNG at print resolution. The picture is drawn in bands in 16-bit floating point (so soft edges and
/// blends keep their precision) and reduced to 8 bits with a fine dither, which hides banding in gradients and shadows.
public enum PNGExporter {
    /// More than this many pixels is refused rather than risking running out of memory.
    public static let maxPixels = 400_000_000

    /// - Parameters:
    ///   - dpi: the print resolution; the file records it so other software opens it at the right size.
    ///   - background: nil keeps the transparency; a colour is laid underneath.
    public static func export(_ doc: Document, assets: AssetProvider? = nil, dpi: Double? = nil, background: RGBA? = nil,
                              dither: Bool = true) throws -> Data {
        let dpi = dpi ?? doc.dpi
        let pxPerMM = dpi / 25.4
        let w = Int((doc.size.width * pxPerMM).rounded()), h = Int((doc.size.height * pxPerMM).rounded())
        guard w > 0, h > 0, w * h <= maxPixels else { throw PNGExportError.tooLarge(width: w, height: h) }

        let bytes = w * h * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        let out = buffer.bindMemory(to: UInt8.self, capacity: bytes)

        guard let working = CGColorSpace(name: CGColorSpace.extendedSRGB) else { buffer.deallocate(); throw PNGExportError.encodingFailed }
        let bandRows = 256
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var half = [UInt16](repeating: 0, count: w * bandRows * 4)

        var y0 = 0
        while y0 < h {
            let rows = min(bandRows, h - y0)
            for i in 0..<(w * rows * 4) { half[i] = 0 }
            half.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: rows, bitsPerComponent: 16, bytesPerRow: w * 8,
                                          space: working, bitmapInfo: info) else { return }
                // Millimetres, y down, with this band's first row at the top of the context.
                ctx.translateBy(x: 0, y: CGFloat(rows))
                ctx.scaleBy(x: 1, y: -1)
                ctx.scaleBy(x: CGFloat(pxPerMM), y: CGFloat(pxPerMM))
                ctx.translateBy(x: 0, y: CGFloat(-Double(y0) / pxPerMM))
                ctx.interpolationQuality = .high
                let region = Rect2(x: 0, y: Double(y0) / pxPerMM, width: doc.size.width, height: Double(rows) / pxPerMM)
                LayerRasterizer.draw(doc, in: ctx, region: region, assets: assets)
            }
            quantize(half, width: w, rows: rows, firstRow: y0, into: out, background: background, dither: dither)
            y0 += rows
        }

        guard let provider = CGDataProvider(dataInfo: buffer, data: buffer, size: bytes, releaseData: { info, _, _ in
            info?.deallocate()
        }), let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: background == nil ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PNGExportError.encodingFailed
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw PNGExportError.encodingFailed }
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PNGExportError.encodingFailed }
        return data as Data
    }

    /// 16-bit float premultiplied rows to 8-bit, with a triangular dither of plus or minus one level on the colour.
    static func quantize(_ half: [UInt16], width: Int, rows: Int, firstRow: Int, into out: UnsafeMutablePointer<UInt8>,
                         background: RGBA?, dither: Bool) {
        let bgR = Float(background?.r ?? 0), bgG = Float(background?.g ?? 0), bgB = Float(background?.b ?? 0)
        let opaque = background != nil
        for ry in 0..<rows {
            let y = firstRow + ry
            for x in 0..<width {
                let i = (ry * width + x) * 4
                let a = halfToFloat(half[i + 3])
                var r = halfToFloat(half[i]), g = halfToFloat(half[i + 1]), b = halfToFloat(half[i + 2])
                var alpha = a
                if opaque {
                    // Over the background colour: the result is opaque.
                    r += bgR * (1 - a); g += bgG * (1 - a); b += bgB * (1 - a)
                    alpha = 1
                }
                let o = (y * width + x) * 4
                let a8 = UInt8(max(0, min(255, (alpha * 255 + 0.5).rounded(.down))))
                func level(_ v: Float, _ c: Int) -> UInt8 {
                    let scaled = v * 255
                    // A value that already sits on a level (flat colours, pure black and white) is left alone; dither
                    // only goes where the 16-bit value falls between two levels, as in gradients, shadows and blends.
                    let onLevel = abs(scaled - scaled.rounded()) < 0.02
                    let noise: Float = dither && !onLevel ? triangularNoise(x, y, c) : 0
                    return UInt8(max(0, min(255, (scaled + noise + 0.5).rounded(.down))))
                }
                var r8 = level(r, 0), g8 = level(g, 1), b8 = level(b, 2)
                // Premultiplied colour must not exceed alpha.
                if !opaque { r8 = min(r8, a8); g8 = min(g8, a8); b8 = min(b8, a8) }
                out[o] = r8; out[o + 1] = g8; out[o + 2] = b8; out[o + 3] = opaque ? 255 : a8
            }
        }
    }

    /// Deterministic noise between -1 and 1 with a triangular spread, from a hash of the pixel position.
    static func triangularNoise(_ x: Int, _ y: Int, _ c: Int) -> Float {
        func hash(_ v: UInt32) -> UInt32 {
            var h = v &* 0x9E3779B1
            h ^= h >> 15; h = h &* 0x85EBCA77; h ^= h >> 13; h = h &* 0xC2B2AE3D; h ^= h >> 16
            return h
        }
        let base = UInt32(truncatingIfNeeded: x) &* 73856093 ^ UInt32(truncatingIfNeeded: y) &* 19349663 ^ UInt32(c) &* 83492791
        let a = Float(hash(base) & 0xFFFF) / 65535, b = Float(hash(base ^ 0xA5A5A5A5) & 0xFFFF) / 65535
        return a + b - 1
    }

    static func halfToFloat(_ h: UInt16) -> Float {
        let sign: Float = (h >> 15) & 1 == 1 ? -1 : 1
        let e = Int((h >> 10) & 0x1f), m = Float(h & 0x3ff)
        if e == 0 { return sign * m * Float(pow(2.0, -24.0)) }
        if e == 31 { return m == 0 ? sign * 65504 : 0 }
        return sign * (1 + m / 1024) * Float(pow(2.0, Double(e - 15)))
    }
}
#endif
