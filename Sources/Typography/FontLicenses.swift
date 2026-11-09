#if canImport(CoreText) && canImport(CoreGraphics)
import Foundation

/// The licence that comes with one bundled font family.
public struct FontLicense: Equatable, Identifiable {
    public var id: String { family }
    public var family: String
    /// The full licence text, as shipped by the font's authors.
    public var text: String
}

public extension FontLibrary {
    /// Names for the licence files, which are called `OFL-<name>.txt`.
    private static let familyNames: [String: String] = [
        "amiri": "Amiri", "bebasneue": "Bebas Neue", "cairo": "Cairo", "elmessiri": "El Messiri", "lobster": "Lobster",
        "montserrat": "Montserrat", "notokufiarabic": "Noto Kufi Arabic", "notonaskharabic": "Noto Naskh Arabic",
        "pacifico": "Pacifico", "playfairdisplay": "Playfair Display", "reemkufi": "Reem Kufi", "tajawal": "Tajawal",
    ]

    /// The licences of the fonts shipped inside the app, for the Acknowledgements screen. The SIL Open Font License asks that
    /// each font's copyright notice and licence travel with the font, so they are read from the same bundle as the fonts.
    static func bundledLicenses() -> [FontLicense] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "txt", subdirectory: "Fonts") ?? []
        var out: [FontLicense] = []
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix("OFL-"), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let key = String(stem.dropFirst(4))
            out.append(FontLicense(family: familyNames[key] ?? key.capitalized, text: text))
        }
        return out.sorted { $0.family < $1.family }
    }
}
#endif
