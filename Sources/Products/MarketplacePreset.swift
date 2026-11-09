import DocumentModel
import Foundation

/// A fixed-size upload a selling site asks for: an exact pixel size, PNG, transparent background, a file size limit.
/// Sellers get rejected for the wrong size, so the app makes the file to the exact pixel count.
///
/// The figures come from public seller guides and not from each site's own rules, which change. The note on each preset
/// says to compare with the upload page before relying on it.
public struct MarketplacePreset: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var dpi: Double
    public var transparentBackground: Bool
    /// The largest file the site accepts, in megabytes; nil when it states no limit.
    public var maxFileMegabytes: Double?
    public var note: String
    /// True keeps the artwork in the middle of the area (mugs, stickers); false keeps it at the top, where shirt printers put a design.
    public var centerVertically: Bool

    public init(id: String, name: String, pixelWidth: Int, pixelHeight: Int, dpi: Double = 300, transparentBackground: Bool = true,
                maxFileMegabytes: Double? = nil, centerVertically: Bool = false, note: String = "") {
        self.id = id; self.name = name; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.dpi = dpi
        self.transparentBackground = transparentBackground; self.maxFileMegabytes = maxFileMegabytes; self.note = note
        self.centerVertically = centerVertically
    }

    /// A size the person types in, for sites that are not in the list.
    public static func custom(pixelWidth: Int, pixelHeight: Int, dpi: Double = 300, transparent: Bool = true) -> MarketplacePreset {
        MarketplacePreset(id: "custom", name: "Custom size", pixelWidth: max(1, pixelWidth), pixelHeight: max(1, pixelHeight), dpi: dpi,
                          transparentBackground: transparent, centerVertically: true,
                          note: "A size you chose. Check the site's upload page for what it needs.")
    }

    /// The print area in millimetres at this preset's resolution.
    public var size: Size2 { Size2(Double(pixelWidth) / dpi * 25.4, Double(pixelHeight) / dpi * 25.4) }

    public var label: String { "\(name) · \(pixelWidth) × \(pixelHeight) px" }

    /// Where artwork with the given bounds goes so that it fills the upload area without being cut off: scaled evenly to
    /// fit, centred sideways and kept at the top, which is where shirt printers place a design. Lengths are millimetres.
    public func placement(for content: Rect2) -> MarketplacePlacement {
        let area = size
        guard content.width > 0, content.height > 0 else { return MarketplacePlacement(scale: 1, offsetX: 0, offsetY: 0) }
        let scale = min(area.width / content.width, area.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        let top = centerVertically ? (area.height - h) / 2 : 0
        return MarketplacePlacement(scale: scale, offsetX: (area.width - w) / 2 - content.x * scale, offsetY: top - content.y * scale)
    }
}

/// How the artwork is moved into the upload area: multiply by `scale`, then add the offsets.
public struct MarketplacePlacement: Equatable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
}

