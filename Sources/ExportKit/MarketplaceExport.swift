#if canImport(CoreGraphics) && canImport(ImageIO)
import CutLine
import DocumentModel
import Foundation
import Products
import Renderer

public struct MarketplaceFile {
    public var name: String
    public var data: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Things to tell the person: the file was enlarged, or is near or over the site's size limit.
    public var warnings: [String]
}

public enum MarketplaceExport {
    /// The visible artwork of the design, on the canvas. Nil when there is none.
    public static func contentBounds(of doc: Document) -> Rect2? {
        var result: Rect2?
        for l in doc.layers where l.isVisible {
            guard let b = doc.worldBounds(of: l.id) else { continue }
            result = result.map { $0.union(b) } ?? b
        }
        return result
    }

    /// The design moved and scaled into the upload area of `preset`, so that exporting it gives exactly the pixel size the site
    /// asks for. `extra` is drawn on top in the upload area's own coordinates (the free plan's watermark goes here).
    public static func arrange(_ doc: Document, for preset: MarketplacePreset, extra: ((Document) -> Layer?)? = nil) -> (document: Document, placement: MarketplacePlacement)? {
        guard let bounds = contentBounds(of: doc) else { return nil }
        let placement = preset.placement(for: bounds)
        let wrapper = Layer(name: "Artwork", content: .group(doc.layers),
                            transform: Transform2D.scale(placement.scale, placement.scale).then(.translation(placement.offsetX, placement.offsetY)))
        var out = Document(title: doc.title, size: preset.size, dpi: preset.dpi, presetID: nil, layers: [wrapper])
        if let top = extra?(out) { out.layers.append(top) }
        return (out, placement)
    }

    /// Writes the PNG for a selling site at the exact pixel size, transparent where the preset says so, 300 DPI, sRGB. If the
    /// file is over the site's size limit it is written again without dithering, which makes it smaller.
    public static func export(_ doc: Document, for preset: MarketplacePreset, assets: AssetProvider? = nil,
                              watermark: ((Document) -> Layer?)? = nil) throws -> MarketplaceFile {
        guard let (arranged, placement) = arrange(doc, for: preset, extra: watermark) else {
            throw ExportError.failed("There is nothing in this design to export yet.")
        }
        let background: RGBA? = preset.transparentBackground ? nil : .white
        var data = try PNGExporter.export(arranged, assets: assets, dpi: preset.dpi, background: background)
        var warnings: [String] = []
        if let limit = preset.maxFileMegabytes {
            let limitBytes = Int(limit * 1_000_000)
            if data.count > limitBytes {
                data = try PNGExporter.export(arranged, assets: assets, dpi: preset.dpi, background: background, dither: false)
            }
            if data.count > limitBytes {
                warnings.append("The file is \(String(format: "%.1f", Double(data.count) / 1_000_000)) MB, over this site's \(Int(limit)) MB limit. Simplify soft shadows and photos, then export again.")
            }
        }
        let fitScale = placement.scale
        if fitScale > 1.25 {
            warnings.append("The artwork was enlarged \(String(format: "%.1f", fitScale)) times to fill the upload area. Pictures in it may look soft; check them at full size.")
        }
        let name = "\(ExportPipeline.baseName(doc.title))-\(preset.id)-\(preset.pixelWidth)x\(preset.pixelHeight).png"
        return MarketplaceFile(name: name, data: data, pixelWidth: preset.pixelWidth, pixelHeight: preset.pixelHeight, warnings: warnings)
    }
}
#endif
