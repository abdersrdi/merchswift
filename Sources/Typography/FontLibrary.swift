#if canImport(CoreText) && canImport(CoreGraphics)
import CoreGraphics
import CoreText
import DocumentModel
import Foundation

/// The fonts the app offers: a bundled set under the SIL Open Font License, plus fonts the user imports.
public final class FontLibrary {
    public static let shared = FontLibrary()

    public struct Family: Equatable {
        public var name: String
        /// True when the family has Arabic letters, so it can be offered for Arabic text.
        public var supportsArabic: Bool
        public var isBundled: Bool
    }

    private let lock = NSLock()
    private var familiesByName: [String: Family] = [:]
    private var didRegisterBundled = false

    private init() {}

    /// Registers the bundled fonts with Core Text for this process. Safe to call more than once.
    public func registerBundledFonts() {
        lock.lock()
        if didRegisterBundled { lock.unlock(); return }
        didRegisterBundled = true
        lock.unlock()
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls { _ = try? register(fontAt: url, bundled: true) }
    }

    /// The font files shipped inside the app.
    public var bundledFontFiles: [URL] {
        Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
    }

    /// Registers a font file (TTF or OTF) the user chose and returns the family names it provides.
    @discardableResult
    public func register(fontAt url: URL) throws -> [String] { try register(fontAt: url, bundled: false) }

    private func register(fontAt url: URL, bundled: Bool) throws -> [String] {
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok, let e = error?.takeRetainedValue() {
            // Registering a font that is already registered reports an error; that is fine.
            let code = CFErrorGetCode(e)
            if code != CTFontManagerError.alreadyRegistered.rawValue { throw e }
        }
        var names: [String] = []
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        for d in descriptors {
            guard let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String else { continue }
            if !names.contains(family) { names.append(family) }
            let font = CTFontCreateWithFontDescriptor(d, 20, nil)
            let arabic = Self.supportsArabic(font)
            lock.lock()
            familiesByName[family] = Family(name: family, supportsArabic: arabic, isBundled: bundled || (familiesByName[family]?.isBundled ?? false))
            lock.unlock()
        }
        return names
    }

    /// Families registered so far, sorted by name.
    public var families: [Family] {
        lock.lock(); defer { lock.unlock() }
        return familiesByName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func hasFamily(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return familiesByName[name] != nil
    }

    static func supportsArabic(_ font: CTFont) -> Bool {
        var chars: [UniChar] = [0x0628, 0x0627]          // beh, alef
        var glyphs = [CGGlyph](repeating: 0, count: 2)
        return CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 2)
    }

    // MARK: Fonts for a style

    /// Core Text's weight trait runs from -1 (thin) to 1 (black); this maps CSS-style 100...900 onto it.
    static func weightTrait(_ weight: Double) -> Double {
        let table: [(Double, Double)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        let w = min(max(weight, 100), 900)
        for i in 1..<table.count where w <= table[i].0 {
            let (w0, t0) = table[i - 1], (w1, t1) = table[i]
            return t0 + (t1 - t0) * (w - w0) / (w1 - w0)
        }
        return table.last!.1
    }

    /// A font for the style at `size` (any unit: outlines come out in the same unit).
    public func font(for style: TextStyle, size: Double) -> CTFont {
        registerBundledFonts()
        var attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: style.family]
        var traits: [CFString: Any] = [kCTFontWeightTrait: Self.weightTrait(style.weight)]
        if style.italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.italicTrait.rawValue }
        attributes[kCTFontTraitsAttribute] = traits

        if !style.features.isEmpty {
            attributes[kCTFontFeatureSettingsAttribute] = style.features.map { f -> [CFString: Any] in
                [kCTFontOpenTypeFeatureTag: f.tag, kCTFontOpenTypeFeatureValue: f.value]
            }
        }

        var descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        var font = CTFontCreateWithFontDescriptor(descriptor, size, nil)

        // Variable fonts: set the weight (and slant) axes directly.
        if let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]], !axes.isEmpty {
            for axis in axes {
                guard let id = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber,
                      let name = axis[kCTFontVariationAxisNameKey] as? String,
                      let lo = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue,
                      let hi = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue else { continue }
                let lower = name.lowercased()
                var value: Double?
                if lower == "weight" { value = min(max(style.weight, lo), hi) }
                else if lower == "slant" { value = style.italic ? lo : hi }      // slant runs from negative to 0
                else if lower == "italic" { value = style.italic ? hi : lo }
                if let value {
                    descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, id, CGFloat(value))
                }
            }
            font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        return font
    }
}
#endif
