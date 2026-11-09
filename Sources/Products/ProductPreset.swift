import CutLine
import DocumentModel
import Foundation

public enum ProductKind: String, Codable, CaseIterable {
    case dieCutSticker, kissCutSheet, tshirt, mug
    /// A flat print file for the back of a phone or tablet case.
    case deviceCase
}

public enum ExportFormat: String, Codable, CaseIterable {
    /// A transparent or flat PNG at the preset's resolution.
    case png
    /// PDF/X-4 with an RGB output intent.
    case pdfX4
    /// PDF/X-4 with the cut path as the spot colour `CutContour`.
    case pdfCutContour
    case svg
    case dxf
    /// PDF converted to CMYK with an ICC profile.
    case cmykPDF
}

/// A product the user designs for: its size, where the cut or print edge is, and the rules the file must meet.
/// All lengths are millimetres. The canvas is the trim size plus the bleed on every side.
public struct ProductPreset: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ProductKind
    /// The finished size: the cut edge of a sheet, the print area of a shirt, the wrap of a mug.
    public var trim: Size2
    /// Artwork must extend this far past the trim edge on every side.
    public var bleed: Double
    /// Important things stay at least this far inside the trim edge.
    public var safeInset: Double
    public var dpi: Double
    /// True when the print has no background: the garment or the sticker material shows through.
    public var transparentBackground: Bool
    /// True when the artwork has to reach the bleed edge (a mug wrap, a poster), because it covers the whole product.
    public var requiresFullBleed: Bool
    /// Parts of the trim area where something gets in the way (a mug handle), in canvas coordinates.
    public var restrictedZones: [Rect2]
    public var exports: [ExportFormat]
    /// A sticker's cut line starts out like this.
    public var cutLine: CutLineSettings?
    /// What a person should check with their supplier before relying on this preset.
    public var note: String
    /// What the restricted zones are called in messages: "handle" on a mug, "camera" on a case.
    public var restrictedZoneName: String
    /// What to tell the person about keeping artwork out of a restricted zone.
    public var restrictedZoneAdvice: String

    public init(id: String, name: String, kind: ProductKind, trim: Size2, bleed: Double, safeInset: Double, dpi: Double = 300,
                transparentBackground: Bool = false, requiresFullBleed: Bool = false, restrictedZones: [Rect2] = [],
                exports: [ExportFormat], cutLine: CutLineSettings? = nil, note: String = "",
                restrictedZoneName: String = "handle",
                restrictedZoneAdvice: String = "The ends of the wrap meet beside the handle, and the handle hides or distorts what is printed there. Keep text and faces out of the handle zone.") {
        self.id = id; self.name = name; self.kind = kind; self.trim = trim; self.bleed = bleed; self.safeInset = safeInset
        self.dpi = dpi; self.transparentBackground = transparentBackground; self.requiresFullBleed = requiresFullBleed
        self.restrictedZones = restrictedZones; self.exports = exports; self.cutLine = cutLine; self.note = note
        self.restrictedZoneName = restrictedZoneName; self.restrictedZoneAdvice = restrictedZoneAdvice
    }

    public var canvas: Size2 { Size2(trim.width + 2 * bleed, trim.height + 2 * bleed) }
    public var trimRect: Rect2 { Rect2(x: bleed, y: bleed, width: trim.width, height: trim.height) }
    public var safeRect: Rect2 {
        Rect2(x: bleed + safeInset, y: bleed + safeInset,
              width: max(trim.width - 2 * safeInset, 0), height: max(trim.height - 2 * safeInset, 0))
    }
    public var canvasRect: Rect2 { Rect2(x: 0, y: 0, width: canvas.width, height: canvas.height) }

    /// A blank document set up for this product.
    public func makeDocument(title: String? = nil) -> Document {
        Document(title: title ?? name, size: canvas, dpi: dpi, presetID: id, cutLine: cutLine)
    }

    /// The same preset at another resolution, for the 600 DPI option on stickers and fine detail.
    public func with(dpi: Double) -> ProductPreset { var p = self; p.dpi = dpi; return p }

    /// A sticker of any size the user picks.
    public static func dieCutSticker(width: Double, height: Double, dpi: Double = 300) -> ProductPreset {
        var p = ProductCatalog.dieCutSticker
        p.trim = Size2(width, height)
        p.dpi = dpi
        p.id = "sticker-die-\(Int(width.rounded()))x\(Int(height.rounded()))"
        p.name = "Die-cut sticker \(Int(width.rounded())) x \(Int(height.rounded())) mm"
        return p
    }
}

/// The presets that ship with the app. Every size and margin here is a starting point: the spec asks for each to be
/// checked against two real suppliers before launch, so the notes say what to confirm.
public enum ProductCatalog {
    private static let supplierNote = "Defaults from common supplier templates. Confirm with your print shop before a production run."

    public static let dieCutSticker = ProductPreset(
        id: "sticker-die-75x75", name: "Die-cut sticker 75 x 75 mm", kind: .dieCutSticker,
        trim: Size2(75, 75), bleed: 3, safeInset: 3, dpi: 300, transparentBackground: true,
        exports: [.pdfCutContour, .png, .svg, .dxf], cutLine: CutLineSettings(offset: 2, smoothing: 1),
        note: supplierNote + " Bleed and safe area are measured from the cut line.")

    public static let kissCutA4 = sheet(id: "sticker-sheet-a4", name: "Kiss-cut sheet A4", width: 210, height: 297)
    public static let kissCutA3 = sheet(id: "sticker-sheet-a3", name: "Kiss-cut sheet A3", width: 297, height: 420)
    public static let kissCutLetter = sheet(id: "sticker-sheet-letter", name: "Kiss-cut sheet Letter", width: 215.9, height: 279.4)

    private static func sheet(id: String, name: String, width: Double, height: Double) -> ProductPreset {
        ProductPreset(id: id, name: name, kind: .kissCutSheet, trim: Size2(width, height), bleed: 3, safeInset: 5,
                      dpi: 300, transparentBackground: true, exports: [.pdfCutContour, .png, .svg, .dxf],
                      cutLine: CutLineSettings(offset: 1.5, smoothing: 0.8),
                      note: supplierNote + " Some cutters need registration marks.")
    }

    // T-shirts: up to about 30 x 40 cm on an adult front, 300 DPI, transparent background.
    public static let tshirtFront = shirt(id: "tee-front", name: "T-shirt front", width: 300, height: 400)
    public static let tshirtBack = shirt(id: "tee-back", name: "T-shirt back", width: 300, height: 400)
    public static let tshirtPocket = shirt(id: "tee-pocket", name: "T-shirt left chest", width: 100, height: 100)
    public static let tshirtSleeve = shirt(id: "tee-sleeve", name: "T-shirt sleeve", width: 90, height: 90)

    private static func shirt(id: String, name: String, width: Double, height: Double) -> ProductPreset {
        ProductPreset(id: id, name: name, kind: .tshirt, trim: Size2(width, height), bleed: 0, safeInset: 5,
                      dpi: 300, transparentBackground: true, exports: [.png, .pdfX4],
                      note: supplierNote + " Maximum print area differs between DTF and DTG machines.")
    }

    // Mugs: the wrap is printed flat and the ends meet at the handle side.
    public static let mug11 = mug(id: "mug-11oz", name: "Mug 11 oz wrap", width: 228.6, height: 88.9)
    public static let mug15 = mug(id: "mug-15oz", name: "Mug 15 oz wrap", width: 241.3, height: 101.6)
    public static let mugLatte = mug(id: "mug-latte", name: "Latte mug wrap", width: 254, height: 95.3)

    private static func mug(id: String, name: String, width: Double, height: Double) -> ProductPreset {
        let bleed = 3.0
        let handleBand = 18.0           // where the wrap's ends meet beside the handle
        let zones = [Rect2(x: bleed, y: bleed, width: handleBand, height: height),
                     Rect2(x: bleed + width - handleBand, y: bleed, width: handleBand, height: height)]
        return ProductPreset(id: id, name: name, kind: .mug, trim: Size2(width, height), bleed: bleed, safeInset: 5, dpi: 300,
                             requiresFullBleed: true, restrictedZones: zones, exports: [.png, .pdfX4],
                             note: supplierNote + " The handle zone and the wrap size differ between mug makers.")
    }

    public static let all: [ProductPreset] = [
        dieCutSticker, kissCutA4, kissCutA3, kissCutLetter,
        tshirtFront, tshirtBack, tshirtPocket, tshirtSleeve,
        mug11, mug15, mugLatte,
    ]

    public static func preset(id: String) -> ProductPreset? { all.first { $0.id == id } ?? DeviceCaseCatalog.preset(id: id) }

    /// The preset a document was made for, including custom sticker sizes whose id carries the size.
    public static func preset(for document: Document) -> ProductPreset? {
        guard let id = document.presetID else { return nil }
        if let p = preset(id: id) { return p.with(dpi: document.dpi) }
        if id.hasPrefix("sticker-die-"), let size = parseSize(String(id.dropFirst("sticker-die-".count))) {
            return ProductPreset.dieCutSticker(width: size.0, height: size.1, dpi: document.dpi)
        }
        return nil
    }

    private static func parseSize(_ text: String) -> (Double, Double)? {
        let parts = text.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return (w, h)
    }
}
