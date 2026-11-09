#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import CutLine
import DocumentModel
import ImageIO
import Products
import XCTest
@testable import ExportKit

/// Stands in for Core Text: a box a quarter em tall and as wide as the text is long.
private final class BoxShaper: TextShaping {
    func shape(text: String, style: TextStyle, boxWidth: Double?) -> ShapedText {
        let w = Double(text.count) * style.size * 0.5, h = style.size * 0.8
        return ShapedText(outline: .rect(Rect2(x: 0, y: 0, width: w, height: h)), size: Size2(w, h))
    }
}

final class WatermarkTests: XCTestCase {
    private func solid(_ name: String, _ r: Rect2) -> Layer {
        Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: r.width, height: r.height)), fill: RGBA(0.1, 0.4, 0.8))),
              transform: .translation(r.x, r.y))
    }

    private func decode(_ data: Data) throws -> (px: [UInt8], w: Int, h: Int) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (px, w, h)
    }

    func testTheMarkSitsInTheBottomRightCornerWithTheRightWidth() throws {
        let doc = Document(size: Size2(100, 80))
        let mark = Watermark.layer(for: doc, shaper: BoxShaper())
        let b = try XCTUnwrap(Document(size: doc.size, layers: [mark]).worldBounds(of: mark.id))
        XCTAssertEqual(b.width, 100 * 0.32 + (mark.content.textStrokeAllowance), accuracy: 1.0)
        XCTAssertEqual(b.maxX, 100 - 8, accuracy: 0.5)
        XCTAssertEqual(b.maxY, 80 - 8, accuracy: 0.5)
        XCTAssertTrue(mark.isLocked)
        XCTAssertEqual(mark.name, "Watermark")
    }

    func testFreeExportCarriesTheMarkAndACleanOneDoesNot() throws {
        var doc = ProductCatalog.tshirtFront.makeDocument(title: "Tee")
        doc.size = Size2(60.96, 40.64)               // 720 x 480 px at 300 DPI
        doc.layers = [solid("art", Rect2(x: 5, y: 5, width: 20, height: 10))]
        let mark = Watermark.layer(for: doc, shaper: BoxShaper())

        let clean = try ExportPipeline().export(doc, preset: ProductCatalog.tshirtFront, options: ExportOptions(formats: [.png], ignorePreflightErrors: true))
        let marked = try ExportPipeline().export(doc, preset: ProductCatalog.tshirtFront, options: ExportOptions(formats: [.png], ignorePreflightErrors: true, watermark: mark))
        let a = try decode(clean[0].data), b = try decode(marked[0].data)
        XCTAssertEqual(a.w, 720); XCTAssertEqual(b.w, 720)

        // Bottom right area: transparent in the clean file, drawn in the marked one.
        func opaque(_ i: (px: [UInt8], w: Int, h: Int)) -> Int {
            var n = 0
            for y in (i.h * 2 / 3)..<i.h { for x in (i.w * 2 / 3)..<i.w where i.px[(y * i.w + x) * 4 + 3] > 40 { n += 1 } }
            return n
        }
        XCTAssertEqual(opaque(a), 0)
        XCTAssertGreaterThan(opaque(b), 500)
        // The artwork itself is the same in both.
        let o = (int(12.0 * 11.811) * a.w + int(10.0 * 11.811)) * 4
        XCTAssertEqual(Array(a.px[o..<(o + 4)]), Array(b.px[o..<(o + 4)]))
    }

    private func int(_ v: Double) -> Int { Int(v) }

    func testTheMarkNeverReachesTheCutFiles() throws {
        var doc = ProductCatalog.dieCutSticker.makeDocument(title: "Cat")
        doc.layers = [Layer(name: "disc", content: .shape(ShapeContent(path: .ellipse(in: Rect2(x: 0, y: 0, width: 50, height: 50)), fill: RGBA(0.8, 0.3, 0.2))),
                            transform: .translation(15.5, 15.5))]
        let mark = Watermark.layer(for: doc, shaper: BoxShaper())
        let pipeline = ExportPipeline()
        let plain = try pipeline.export(doc, options: ExportOptions(formats: [.dxf, .svg]))
        let marked = try pipeline.export(doc, options: ExportOptions(formats: [.dxf, .svg], watermark: mark))
        XCTAssertEqual(plain[0].data, marked[0].data, "the DXF cut path is identical with and without the mark")
        let svg = String(decoding: marked[1].data, as: UTF8.self)
        XCTAssertTrue(svg.contains("id=\"Watermark\""), "but the artwork file shows it")
        XCTAssertFalse(String(decoding: plain[1].data, as: UTF8.self).contains("Watermark"))
    }

    func testPDFsAlsoShowTheMark() throws {
        var doc = ProductCatalog.tshirtFront.makeDocument(title: "Tee")
        doc.layers = [solid("art", Rect2(x: 50, y: 50, width: 100, height: 100))]
        let mark = Watermark.layer(for: doc, shaper: BoxShaper())
        let plain = try ExportPipeline().export(doc, options: ExportOptions(formats: [.pdfX4]))
        let marked = try ExportPipeline().export(doc, options: ExportOptions(formats: [.pdfX4], watermark: mark))
        XCTAssertGreaterThan(marked[0].data.count, 0)
        XCTAssertNotEqual(plain[0].data.count, marked[0].data.count)
    }
}

private extension LayerContent {
    /// Half the stroke width on each side widens the outline's bounds a little.
    var textStrokeAllowance: Double {
        if case .text(let t) = self { return t.style.stroke?.width ?? 0 }
        return 0
    }
}
#endif
