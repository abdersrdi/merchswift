import XCTest
import CutLine
@testable import Export

final class StickerPDFTests: XCTestCase {
    /// A red star-ish blob with a white border on a transparent background.
    private func sampleArtwork(size: Int = 360) -> RGBAImage {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let c = Double(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
                let r = (dx * dx + dy * dy).squareRoot()
                let a = atan2(dy, dx)
                let edge = 110 + 30 * cos(5 * a)
                let i = (y * size + x) * 4
                if r <= edge {
                    let inner = r <= edge - 12
                    px[i] = inner ? 214 : 255
                    px[i + 1] = inner ? 40 : 255
                    px[i + 2] = inner ? 52 : 255
                    px[i + 3] = 255
                }
            }
        }
        return RGBAImage(width: size, height: size, pixels: px)
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("merchswift-\(UUID().uuidString)-\(name)")
    }

    func testWritesPDFWithCutContourAndOutputIntent() throws {
        let art = sampleArtwork()
        let cut = try CutLineGenerator.generate(from: art.alpha, options: CutLineOptions(offset: 14, smoothing: 4))
        let url = tempURL("sticker.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try StickerPDF.write(artwork: art, cut: cut, to: url, options: StickerPDFOptions(dpi: 300))

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("%PDF-1.6"))
        XCTAssertTrue(text.contains("/Separation"))
        XCTAssertTrue(text.contains("/CutContour"))
        XCTAssertTrue(text.contains("/DeviceCMYK"))
        XCTAssertTrue(text.contains("/OutputIntents"))
        XCTAssertTrue(text.contains("/GTS_PDFX"))
        XCTAssertTrue(text.contains("/DestOutputProfile"))
        XCTAssertTrue(text.contains("pdfxid:GTS_PDFXVersion=\"PDF/X-4\""))
        XCTAssertTrue(text.contains("/TrimBox"))
        XCTAssertTrue(text.contains("/BleedBox"))
        XCTAssertTrue(text.hasSuffix("%%EOF\n") || text.contains("%%EOF"))
    }

    func testReopensWithPDFio() throws {
        let art = sampleArtwork()
        let cut = try CutLineGenerator.generate(from: art.alpha, options: CutLineOptions(offset: 10))
        let url = tempURL("reopen.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try StickerPDF.write(artwork: art, cut: cut, to: url)
        let info = try StickerPDF.inspect(url)
        XCTAssertEqual(info.pageCount, 1)
        XCTAssertEqual(info.version, "1.6")
    }

    func testPageSizeMatchesDPI() throws {
        let art = sampleArtwork(size: 300)
        let cut = try CutLineGenerator.generate(from: art.alpha, options: CutLineOptions(offset: 8))
        let url = tempURL("size.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try StickerPDF.write(artwork: art, cut: cut, to: url, options: StickerPDFOptions(dpi: 300))
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        // 300 px at 300 dpi is exactly 1 inch = 72 pt.
        XCTAssertTrue(text.contains("/MediaBox [0 0 72 72]"), "media box missing or wrong size")
    }

    func testVersionString() {
        XCTAssertTrue(StickerPDF.pdfioVersion.hasPrefix("PDFio 1."))
    }

    /// Writes the proof files into $MERCHSWIFT_PROOF_DIR (set by CI) so they can be inspected as an artifact.
    func testWriteProofFiles() throws {
        guard let dir = ProcessInfo.processInfo.environment["MERCHSWIFT_PROOF_DIR"] else { throw XCTSkip("no proof dir") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let art = sampleArtwork(size: 900)
        let cut = try CutLineGenerator.generate(from: art.alpha, options: CutLineOptions(offset: 36, smoothing: 10))
        try StickerPDF.write(artwork: art, cut: cut, to: out.appendingPathComponent("sticker-cutcontour.pdf"),
                             options: StickerPDFOptions(title: "MerchSwift proof sticker", dpi: 300))
        let mm = cut.scaled(by: 25.4 / 300)
        let h = 900 * 25.4 / 300
        try SVGWriter.svg(cut: mm, widthMM: h, heightMM: h).write(to: out.appendingPathComponent("sticker-cut.svg"),
                                                                    atomically: true, encoding: .utf8)
        try DXFWriter.dxf(cut: mm.flippedY(height: h)).write(to: out.appendingPathComponent("sticker-cut.dxf"),
                                                              atomically: true, encoding: .utf8)
    }
}
