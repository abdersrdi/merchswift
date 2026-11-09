#if canImport(CoreText) && canImport(CoreGraphics)
import XCTest
@testable import Typography

final class FontLicenseTests: XCTestCase {
    /// Every bundled font file must come with its licence, because the SIL Open Font License requires it to travel with the font.
    func testEveryBundledFontFamilyHasItsLicense() {
        let licenses = FontLibrary.bundledLicenses()
        XCTAssertEqual(licenses.count, 12)
        for l in licenses {
            XCTAssertTrue(l.text.contains("SIL OPEN FONT LICENSE"), "\(l.family) has no licence text")
            XCTAssertTrue(l.text.contains("Copyright"), "\(l.family) has no copyright line")
        }
        XCTAssertEqual(Set(licenses.map(\.family)).count, licenses.count)
        XCTAssertTrue(licenses.contains { $0.family == "Cairo" })
        XCTAssertTrue(licenses.contains { $0.family == "Noto Naskh Arabic" })
    }

    func testEveryFontFileBelongsToALicensedFamily() {
        let families = FontLibrary.bundledLicenses().map { $0.family.lowercased().replacingOccurrences(of: " ", with: "") }
        for url in FontLibrary.shared.bundledFontFiles {
            let file = url.deletingPathExtension().lastPathComponent.lowercased()
            XCTAssertTrue(families.contains { file.hasPrefix($0) }, "\(url.lastPathComponent) has no matching licence")
        }
    }
}
#endif
