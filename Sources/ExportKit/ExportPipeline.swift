#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import CutLine
import DocumentModel
import Export
import Foundation
import Preflight
import Products
import Renderer

public struct ExportedFile: Equatable {
    public var name: String
    public var format: ExportFormat
    public var data: Data
}

public struct ExportOptions {
    /// What to write; nil means everything the product calls for.
    public var formats: [ExportFormat]?
    /// Overrides the product's print resolution (for the 600 DPI option).
    public var dpi: Double?
    /// Writes the files even when the preflight found errors.
    public var ignorePreflightErrors = false
    /// A layer drawn over the artwork in every file that shows the artwork (PNG, PDF and SVG). It never reaches the cut
    /// line, the DXF or the print checks. Free exports carry the MerchSwift mark; nil leaves the artwork clean.
    public var watermark: Layer?

    public init(formats: [ExportFormat]? = nil, dpi: Double? = nil, ignorePreflightErrors: Bool = false, watermark: Layer? = nil) {
        self.formats = formats; self.dpi = dpi; self.ignorePreflightErrors = ignorePreflightErrors; self.watermark = watermark
    }
}

public enum ExportError: Error, CustomStringConvertible {
    /// The preflight found errors that would make the files unusable.
    case blocked(PreflightReport)
    case noCutLine
    case noCMYKProfile
    case failed(String)

    public var description: String {
        switch self {
        case .blocked(let r): return "The print checks found \(r.errors) problem\(r.errors == 1 ? "" : "s") to fix first: " + r.issues.filter { $0.severity == .error }.map { $0.title }.joined(separator: "; ")
        case .noCutLine: return "This design has no cut line settings, so no cut files can be made."
        case .noCMYKProfile: return "No CMYK colour profile is available on this device."
        case .failed(let m): return m
        }
    }
}

/// Runs the print checks and writes every file a product needs: PNG, PDF/X-4, PDF with a cut line, SVG, DXF and CMYK PDF,
/// or all of them in one ZIP.
public final class ExportPipeline {
    private let assets: AssetProvider?
    private let cmyk: SystemCMYKConverter?
    private let pixelSource: PixelSource?

    public init(assets: AssetProvider? = nil, cmyk: SystemCMYKConverter? = SystemCMYKConverter()) {
        self.assets = assets
        self.cmyk = cmyk
        self.pixelSource = assets.map { CGPixelSource($0) }
    }

    /// The preset the document was made for, if the caller did not give one.
    private func presetFor(_ doc: Document, _ given: ProductPreset?) -> ProductPreset? { given ?? ProductCatalog.preset(for: doc) }

    private func formats(_ doc: Document, _ preset: ProductPreset?, _ options: ExportOptions) -> [ExportFormat] {
        options.formats ?? preset?.exports ?? [.png, .pdfX4]
    }

    /// The print checks, including the cut line and (when a CMYK profile exists) colour gamut.
    public func preflight(_ doc: Document, preset: ProductPreset? = nil) -> PreflightReport {
        let p = presetFor(doc, preset)
        var cut: CutPath?
        if p?.cutLine != nil || doc.cutLine != nil { cut = try? CutLineBuilder.cutPath(for: doc, assets: assets) }
        return Preflight.run(doc, preset: p, cutPath: cut, gamut: cmyk)
    }

    public func export(_ doc: Document, preset: ProductPreset? = nil, options: ExportOptions = ExportOptions()) throws -> [ExportedFile] {
        let p = presetFor(doc, preset)
        let wanted = formats(doc, p, options)
        let needsCut = wanted.contains(.pdfCutContour) || wanted.contains(.dxf)
        var cut: CutPath?
        if needsCut || doc.cutLine != nil || p?.cutLine != nil {
            if needsCut && doc.cutLine == nil && p?.cutLine == nil { throw ExportError.noCutLine }
            do { cut = try CutLineBuilder.cutPath(for: doc, assets: assets, settings: doc.cutLine ?? p?.cutLine) }
            catch { if needsCut { throw ExportError.failed("The cut line could not be made: \(error)") } }
        }

        let report = Preflight.run(doc, preset: p, cutPath: cut, gamut: cmyk)
        if !report.canExport && !options.ignorePreflightErrors { throw ExportError.blocked(report) }

        // What the artwork files show: the design, plus the watermark if there is one. The cut line and the print
        // checks above were made from the design alone.
        var shown = doc
        if let mark = options.watermark { shown.layers.append(mark) }

        let base = Self.baseName(doc.title)
        let dpi = options.dpi ?? p?.dpi ?? doc.dpi
        let trim = p?.trimRect
        var files: [ExportedFile] = []

        for format in wanted {
            switch format {
            case .png:
                let transparent = p?.transparentBackground ?? true
                let data = try PNGExporter.export(shown, assets: assets, dpi: dpi, background: transparent ? nil : RGBA.white)
                files.append(ExportedFile(name: "\(base).png", format: .png, data: data))

            case .pdfX4:
                let data = try pdf(shown, DocumentPDFOptions(title: doc.title, trim: trim))
                files.append(ExportedFile(name: "\(base).pdf", format: .pdfX4, data: data))

            case .pdfCutContour:
                guard let cut else { throw ExportError.noCutLine }
                let data = try pdf(shown, DocumentPDFOptions(title: doc.title, trim: trim, cutLine: cut))
                files.append(ExportedFile(name: "\(base)-cut.pdf", format: .pdfCutContour, data: data))

            case .svg:
                let svg = DocumentSVG.svg(shown, assets: pixelSource, cutLine: cut)
                files.append(ExportedFile(name: "\(base).svg", format: .svg, data: Data(svg.utf8)))

            case .dxf:
                guard let cut else { throw ExportError.noCutLine }
                let dxf = DXFWriter.dxf(cut: cut.flippedY(height: doc.size.height))
                files.append(ExportedFile(name: "\(base)-cut.dxf", format: .dxf, data: Data(dxf.utf8)))

            case .cmykPDF:
                guard let cmyk else { throw ExportError.noCMYKProfile }
                let data = try pdf(shown, DocumentPDFOptions(title: doc.title, trim: trim, cutLine: cut, colorMode: .cmyk(cmyk)))
                files.append(ExportedFile(name: "\(base)-cmyk.pdf", format: .cmykPDF, data: data))
            }
        }
        return files
    }

    /// Everything in one ZIP: the files, plus a short text file listing the print checks that still have warnings.
    public func exportArchive(_ doc: Document, preset: ProductPreset? = nil, options: ExportOptions = ExportOptions()) throws -> Data {
        let files = try export(doc, preset: preset, options: options)
        var zip = ZipWriter()
        for f in files { zip.add(name: f.name, data: f.data) }
        let report = preflight(doc, preset: preset)
        if !report.issues.isEmpty {
            var text = "Print checks for \"\(doc.title)\"\n\n"
            for i in report.issues { text += "- [\(i.severity == .error ? "error" : "warning")] \(i.title)\n  \(i.detail)\n" }
            zip.add(name: "print-checks.txt", data: Data(text.utf8))
        }
        return zip.data()
    }

    /// Writes the files into a folder and returns where they went.
    public func write(_ doc: Document, preset: ProductPreset? = nil, options: ExportOptions = ExportOptions(), to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for f in try export(doc, preset: preset, options: options) {
            let url = folder.appendingPathComponent(f.name)
            try f.data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    // MARK: Helpers

    private func pdf(_ doc: Document, _ options: DocumentPDFOptions) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("merchswift-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentPDF.write(doc, assets: pixelSource, to: url, options: options)
        return try Data(contentsOf: url)
    }

    /// A file name from the design's title: letters and digits (any script) with dashes between words.
    static func baseName(_ title: String) -> String {
        var out = ""
        var lastDash = true
        for ch in title.unicodeScalars {
            if ch.properties.isAlphabetic || ch.properties.numericType != nil {
                out.unicodeScalars.append(ch)
                lastDash = false
            } else if !lastDash {
                out += "-"
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "design" : out
    }
}
#endif
