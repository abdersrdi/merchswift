#if canImport(CoreGraphics)
import CoreGraphics
import CutLine
import DocumentModel
import Export
import Foundation
import Renderer

/// Turns an `AssetProvider` (pictures as Core Graphics images) into the pixel source the PDF writer wants.
public final class CGPixelSource: PixelSource {
    private let assets: AssetProvider
    public init(_ assets: AssetProvider) { self.assets = assets }

    public func pixels(for assetID: String) -> RGBAImage? {
        guard let cg = assets.image(for: assetID) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var premult = [UInt8](repeating: 0, count: w * h * 4)
        premult.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Back to straight alpha, which is what a PDF image with a soft mask holds.
        for i in 0..<(w * h) {
            let a = Int(premult[i * 4 + 3])
            if a > 0 && a < 255 {
                for c in 0..<3 { premult[i * 4 + c] = UInt8(min(255, (Int(premult[i * 4 + c]) * 255 + a / 2) / a)) }
            }
        }
        return RGBAImage(width: w, height: h, pixels: premult)
    }
}

/// Builds a sticker's cut line from what the design actually draws.
public enum CutLineBuilder {
    /// The cut path in canvas millimetres (y down). The design is drawn at `pixelsPerMM`, its outline traced and grown by the
    /// document's cut offset, and the result fitted with smooth curves.
    public static func cutPath(for doc: Document, assets: AssetProvider? = nil, settings: CutLineSettings? = nil,
                               pixelsPerMM: Double = 8) throws -> CutPath {
        let s = settings ?? doc.cutLine ?? CutLineSettings()
        let w = max(1, Int((doc.size.width * pixelsPerMM).rounded())), h = max(1, Int((doc.size.height * pixelsPerMM).rounded()))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: CGFloat(pixelsPerMM), y: CGFloat(pixelsPerMM))
            LayerRasterizer.draw(doc, in: ctx, region: doc.canvas, assets: assets)
        }
        var alpha = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { alpha[i] = rgba[i * 4 + 3] }
        let options = CutLineOptions(offset: s.offset * pixelsPerMM, smoothing: s.smoothing * pixelsPerMM, tolerance: 0.35)
        let px = try CutLineGenerator.generate(from: AlphaImage(width: w, height: h, alpha: alpha), options: options)
        return px.scaled(by: 1 / pixelsPerMM)
    }
}
#endif
