#if canImport(Vision) && canImport(CoreGraphics)
import CoreGraphics
import CoreVideo
import Export
import Foundation
import Vision

public enum CutoutError: Error, Equatable {
    case badImage
    case noSubject
    case unsupportedMask
}

/// Background removal with Apple's on-device Vision framework. Nothing leaves the device.
public enum VisionCutout {
    /// Finds the foreground subject(s) in the picture and returns it with the background made transparent. Run it off the
    /// main thread. Follow it with `AlphaTools.refine` to clean the edge.
    public static func removeBackground(from image: RGBAImage) throws -> RGBAImage {
        guard let cg = makeCGImage(image) else { throw CutoutError.badImage }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw CutoutError.noSubject }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        let mask = try floats(from: buffer)
        let resized = CutoutMask.resize(mask.values, width: mask.width, height: mask.height, toWidth: image.width, toHeight: image.height)
        return CutoutMask.apply(resized, to: image)
    }

    // MARK: Bridging

    /// A picture as a CGImage (straight alpha, sRGB).
    public static func makeCGImage(_ image: RGBAImage) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Reads any CGImage into 8-bit sRGB RGBA, not premultiplied.
    public static func makeRGBA(_ cg: CGImage) -> RGBAImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        for i in 0..<(w * h) {
            let a = Int(pixels[i * 4 + 3])
            if a > 0 && a < 255 {
                for c in 0..<3 { pixels[i * 4 + c] = UInt8(min(255, (Int(pixels[i * 4 + c]) * 255 + a / 2) / a)) }
            }
        }
        return RGBAImage(width: w, height: h, pixels: pixels)
    }

    private static func floats(from buffer: CVPixelBuffer) throws -> (values: [Float], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CutoutError.unsupportedMask }
        var out = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) / 255 }
            }
        default:
            throw CutoutError.unsupportedMask
        }
        return (out, w, h)
    }
}
#endif
