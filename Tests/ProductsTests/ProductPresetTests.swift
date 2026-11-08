import XCTest
import DocumentModel
@testable import Products

final class ProductPresetTests: XCTestCase {
    func testCanvasIsTrimPlusBleedOnEverySide() {
        let p = ProductCatalog.dieCutSticker
        XCTAssertEqual(p.canvas, Size2(81, 81))
        XCTAssertEqual(p.trimRect, Rect2(x: 3, y: 3, width: 75, height: 75))
        XCTAssertEqual(p.safeRect, Rect2(x: 6, y: 6, width: 69, height: 69))
    }

    func testEveryPresetIsSane() {
        var ids = Set<String>()
        for p in ProductCatalog.all {
            XCTAssertTrue(ids.insert(p.id).inserted, "duplicate id \(p.id)")
            XCTAssertGreaterThan(p.trim.width, 0, p.id)
            XCTAssertGreaterThan(p.trim.height, 0, p.id)
            XCTAssertGreaterThanOrEqual(p.bleed, 0, p.id)
            XCTAssertGreaterThan(p.safeRect.width, 0, p.id)
            XCTAssertTrue(p.safeRect.minX >= p.trimRect.minX && p.safeRect.maxX <= p.trimRect.maxX, p.id)
            XCTAssertFalse(p.exports.isEmpty, p.id)
            XCTAssertGreaterThanOrEqual(p.dpi, 300, p.id)
            XCTAssertFalse(p.note.isEmpty, "every default says what to confirm: \(p.id)")
            for zone in p.restrictedZones {
                XCTAssertTrue(p.canvasRect.contains(Point(zone.minX, zone.minY)) && p.canvasRect.contains(Point(zone.maxX, zone.maxY)), p.id)
            }
        }
    }

    func testProductRules() {
        XCTAssertEqual(ProductCatalog.tshirtFront.trim, Size2(300, 400))
        XCTAssertTrue(ProductCatalog.tshirtFront.transparentBackground)
        XCTAssertEqual(ProductCatalog.tshirtFront.bleed, 0)
        XCTAssertTrue(ProductCatalog.mug11.requiresFullBleed)
        XCTAssertEqual(ProductCatalog.mug11.restrictedZones.count, 2)
        XCTAssertEqual(ProductCatalog.mug11.trim.width, 9 * 25.4, accuracy: 1e-9)
        XCTAssertEqual(ProductCatalog.mug11.trim.height, 3.5 * 25.4, accuracy: 1e-9)
        XCTAssertTrue(ProductCatalog.dieCutSticker.exports.contains(.pdfCutContour))
        XCTAssertNotNil(ProductCatalog.dieCutSticker.cutLine)
        XCTAssertNil(ProductCatalog.tshirtFront.cutLine)
        XCTAssertEqual(ProductCatalog.kissCutA4.trim, Size2(210, 297))
        XCTAssertEqual(ProductCatalog.kissCutLetter.trim.width, 8.5 * 25.4, accuracy: 1e-9)
    }

    func testMakeDocument() {
        let doc = ProductCatalog.mug15.makeDocument()
        XCTAssertEqual(doc.size, ProductCatalog.mug15.canvas)
        XCTAssertEqual(doc.dpi, 300)
        XCTAssertEqual(doc.presetID, "mug-15oz")
        let sticker = ProductCatalog.dieCutSticker.makeDocument(title: "Cat")
        XCTAssertEqual(sticker.title, "Cat")
        XCTAssertEqual(sticker.cutLine, CutLineSettings(offset: 2, smoothing: 1))
    }

    func testResolutionOption() {
        let fine = ProductCatalog.dieCutSticker.with(dpi: 600)
        XCTAssertEqual(fine.dpi, 600)
        XCTAssertEqual(fine.canvas, ProductCatalog.dieCutSticker.canvas)
        XCTAssertEqual(fine.makeDocument().dpi, 600)
    }

    func testCustomStickerSizeRoundTripsThroughTheDocument() throws {
        let p = ProductPreset.dieCutSticker(width: 90, height: 60, dpi: 600)
        XCTAssertEqual(p.canvas, Size2(96, 66))
        let doc = p.makeDocument()
        let found = try XCTUnwrap(ProductCatalog.preset(for: doc))
        XCTAssertEqual(found.trim, Size2(90, 60))
        XCTAssertEqual(found.dpi, 600)
        XCTAssertNil(ProductCatalog.preset(for: Document(size: Size2(10, 10))))
    }

    func testLookupById() {
        XCTAssertEqual(ProductCatalog.preset(id: "tee-pocket")?.trim, Size2(100, 100))
        XCTAssertNil(ProductCatalog.preset(id: "nope"))
    }

    func testPresetIsCodable() throws {
        for p in ProductCatalog.all {
            let back = try JSONDecoder().decode(ProductPreset.self, from: try JSONEncoder().encode(p))
            XCTAssertEqual(back, p)
        }
    }

    func testDocumentWithCutSettingsAndImagePixelsIsCodable() throws {
        var doc = ProductCatalog.dieCutSticker.makeDocument()
        doc.layers = [Layer(name: "i", content: .image(ImageContent(assetID: "a", size: Size2(50, 50), pixelWidth: 800, pixelHeight: 600)))]
        let back = try JSONDecoder().decode(Document.self, from: try JSONEncoder().encode(doc))
        XCTAssertEqual(back, doc)
        // Old documents without the new fields still open.
        let old = #"{"formatVersion":1,"title":"x","size":{"width":10,"height":10},"dpi":300,"layers":[],"guides":[]}"#
        XCTAssertNil(try JSONDecoder().decode(Document.self, from: Data(old.utf8)).cutLine)
    }
}
