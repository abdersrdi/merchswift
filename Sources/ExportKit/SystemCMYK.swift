#if canImport(CoreGraphics)
import CoreGraphics
import DocumentModel
import Export
import Foundation
import Preflight

/// CMYK conversion through ColorSync. By default it uses the system's generic CMYK profile; a print shop's own
/// profile (Shop plan) can be passed as ICC data instead. The same object answers the gamut check: a colour is out
/// of gamut when going to CMYK and back changes it visibly.
public final class SystemCMYKConverter: ColorConverting, GamutChecking {
    public let profile: Data
    public let conditionName: String
    private let cmykSpace: CGColorSpace
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var cache: [UInt32: (Double, Double, Double, Double)] = [:]
    /// A colour counts as out of gamut when a channel moves by more than this (out of 255) after the round trip.
    public var gamutTolerance: Double = 8

    /// - Parameters:
    ///   - iccProfile: a CMYK ICC profile; nil uses the system generic CMYK profile.
    ///   - name: how the profile is named in the PDF's output intent.
    public init?(iccProfile: Data? = nil, name: String? = nil) {
        if let data = iccProfile {
            guard let space = CGColorSpace(iccData: data as CFData), space.model == .cmyk else { return nil }
            cmykSpace = space
            profile = data
            conditionName = name ?? "Custom CMYK profile"
        } else {
            guard let space = CGColorSpace(name: CGColorSpace.genericCMYK), let icc = space.copyICCData() else { return nil }
            cmykSpace = space
            profile = icc as Data
            conditionName = name ?? "Generic CMYK Profile"
        }
    }

    // MARK: ColorConverting

    public func cmyk(from color: RGBA) -> (c: Double, m: Double, y: Double, k: Double) {
        let r = UInt32((min(max(color.r, 0), 1) * 255).rounded()), g = UInt32((min(max(color.g, 0), 1) * 255).rounded()),
            b = UInt32((min(max(color.b, 0), 1) * 255).rounded())
        let key = r << 16 | g << 8 | b
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return (hit.0, hit.1, hit.2, hit.3) }
        lock.unlock()

        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: cmykSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(CGColor(colorSpace: srgb, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let value = (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255, Double(px[3]) / 255)
        lock.lock(); cache[key] = value; lock.unlock()
        return (value.0, value.1, value.2, value.3)
    }

    public func cmykPixels(_ image: RGBAImage) -> [UInt8] {
        let w = image.width, h = image.height
        // An opaque RGB copy (the alpha is kept separately), drawn into a CMYK bitmap so ColorSync does the conversion.
        var rgbx = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            rgbx[i * 4] = image.pixels[i * 4]; rgbx[i * 4 + 1] = image.pixels[i * 4 + 1]; rgbx[i * 4 + 2] = image.pixels[i * 4 + 2]
        }
        var cmykBytes = [UInt8](repeating: 0, count: w * h * 4)
        rgbx.withUnsafeMutableBytes { src in
            guard let srcCtx = CGContext(data: src.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let cg = srcCtx.makeImage() else { return }
            cmykBytes.withUnsafeMutableBytes { dst in
                guard let dstCtx = CGContext(data: dst.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: cmykSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                dstCtx.interpolationQuality = .none
                dstCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        var out = [UInt8](repeating: 0, count: w * h * 5)
        for i in 0..<(w * h) {
            out[i * 5] = cmykBytes[i * 4]; out[i * 5 + 1] = cmykBytes[i * 4 + 1]
            out[i * 5 + 2] = cmykBytes[i * 4 + 2]; out[i * 5 + 3] = cmykBytes[i * 4 + 3]
            out[i * 5 + 4] = image.pixels[i * 4 + 3]
        }
        return out
    }

    // MARK: Gamut and soft proof

    /// The screen colour that CMYK ink would actually give for these amounts.
    public func rgb(fromCMYK c: Double, _ m: Double, _ y: Double, _ k: Double) -> RGBA {
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.setFillColor(CGColor(colorSpace: cmykSpace, components: [CGFloat(c), CGFloat(m), CGFloat(y), CGFloat(k), 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return RGBA(Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    /// What this colour looks like once printed: the colour after a trip through CMYK.
    public func printed(_ color: RGBA) -> RGBA {
        let k = cmyk(from: color)
        var back = rgb(fromCMYK: k.c, k.m, k.y, k.k)
        back.a = color.a
        return back
    }

    public func isInGamut(_ color: RGBA) -> Bool {
        let p = printed(color)
        let d = max(abs(p.r - color.r), abs(p.g - color.g), abs(p.b - color.b)) * 255
        return d <= gamutTolerance
    }

    public func nearestInGamut(_ color: RGBA) -> RGBA { printed(color) }

    /// A picture as it will look printed, for the soft proof: every pixel goes to CMYK and back.
    public func softProof(_ image: RGBAImage) -> RGBAImage {
        let w = image.width, h = image.height
        var cmykBytes = cmykPixels(image)
        var chans = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { for c in 0..<4 { chans[i * 4 + c] = cmykBytes[i * 5 + c] } }
        cmykBytes.removeAll()
        var out = image.pixels
        chans.withUnsafeMutableBytes { src in
            guard let provider = CGDataProvider(data: Data(bytes: src.baseAddress!, count: w * h * 4) as CFData),
                  let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cmykSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent) else { return }
            var rgbx = [UInt8](repeating: 0, count: w * h * 4)
            rgbx.withUnsafeMutableBytes { dst in
                guard let ctx = CGContext(data: dst.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
                ctx.interpolationQuality = .none
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            for i in 0..<(w * h) { out[i * 4] = rgbx[i * 4]; out[i * 4 + 1] = rgbx[i * 4 + 1]; out[i * 4 + 2] = rgbx[i * 4 + 2] }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }
}
#endif
