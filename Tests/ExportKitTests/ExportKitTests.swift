#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(ColorSync)
import CoreGraphics
import CutLine
import DocumentModel
import Export
import ImageIO
import Preflight
import Products
import Renderer
import XCTest
@testable import ExportKit

private final class TestAssets: AssetProvider {
    var images: [String: CGImage] = [:]
    func image(for assetID: String) -> CGImage? { images[assetID] }
}

private func solidImage(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) { px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b }
    return px.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}

private func rect(_ name: String, _ r: Rect2, _ c: RGBA, opacity: Double = 1) -> Layer {
    Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: r.width, height: r.height)), fill: c)),
          transform: .translation(r.x, r.y), opacity: opacity)
}

/// RGBA pixels (premultiplied) of a PNG, with its size.
private func decodePNG(_ data: Data) throws -> (px: [UInt8], w: Int, h: Int, dpi: Double?) {
    let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let dpi = props?[kCGImagePropertyDPIWidth] as? Double
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (px, w, h, dpi)
}

final class PNGExportTests: XCTestCase {
    private func pixel(_ i: (px: [UInt8], w: Int, h: Int, dpi: Double?), _ x: Int, _ y: Int) -> [Int] {
        let o = (y * i.w + x) * 4
        return [Int(i.px[o]), Int(i.px[o + 1]), Int(i.px[o + 2]), Int(i.px[o + 3])]
    }

    func testSizeResolutionAndPlacement() throws {
        // 25.4 x 12.7 mm at 300 DPI is 300 x 150 pixels; the red box starts at 2.54 mm = 30 px and is 120 x 60 px.
        let doc = Document(size: Size2(25.4, 12.7), dpi: 300, layers: [rect("red", Rect2(x: 2.54, y: 2.54, width: 10.16, height: 5.08), RGBA(1, 0, 0))])
        let png = try decodePNG(try PNGExporter.export(doc, dither: false))
        XCTAssertEqual(png.w, 300); XCTAssertEqual(png.h, 150)
        XCTAssertEqual(try XCTUnwrap(png.dpi), 300, accuracy: 1)
        XCTAssertEqual(pixel(png, 60, 60), [255, 0, 0, 255])
        XCTAssertEqual(pixel(png, 10, 10)[3], 0, "outside the shape is transparent")
        XCTAssertEqual(pixel(png, 200, 100)[3], 0)
        XCTAssertEqual(pixel(png, 29, 60)[3], 0, "the edge is where 2.54 mm says")
        XCTAssertEqual(pixel(png, 31, 60)[3], 255)
        XCTAssertEqual(pixel(png, 60, 29)[3], 0, "y runs downward")
    }

    func testSixHundredDPIOption() throws {
        let doc = Document(size: Size2(25.4, 25.4), dpi: 300, layers: [rect("r", Rect2(x: 0, y: 0, width: 25.4, height: 25.4), .black)])
        let png = try decodePNG(try PNGExporter.export(doc, dpi: 600))
        XCTAssertEqual(png.w, 600)
        XCTAssertEqual(try XCTUnwrap(png.dpi), 600, accuracy: 1)
    }

    func testBackgroundColourReplacesTransparency() throws {
        let doc = Document(size: Size2(10.16, 10.16), dpi: 300, layers: [rect("r", Rect2(x: 0, y: 0, width: 5.08, height: 10.16), RGBA(0, 0, 1))])
        let png = try decodePNG(try PNGExporter.export(doc, background: .white, dither: false))
        XCTAssertEqual(pixel(png, 10, 10), [0, 0, 255, 255])
        XCTAssertEqual(pixel(png, 100, 10), [255, 255, 255, 255])
    }

    func testHalfOpacityIsPremultipliedAndDithered() throws {
        let doc = Document(size: Size2(10.16, 10.16), dpi: 300, layers: [rect("half", Rect2(x: 0, y: 0, width: 10.16, height: 10.16), .black, opacity: 0.5)])
        let flat = try decodePNG(try PNGExporter.export(doc, background: .white, dither: false))
        let dithered = try decodePNG(try PNGExporter.export(doc, background: .white, dither: true))
        func values(_ i: (px: [UInt8], w: Int, h: Int, dpi: Double?)) -> Set<Int> {
            var s = Set<Int>()
            for y in 0..<i.h { for x in 0..<i.w { s.insert(Int(i.px[(y * i.w + x) * 4])) } }
            return s
        }
        XCTAssertEqual(values(flat), [128], "without dither every pixel is the same")
        let v = values(dithered)
        XCTAssertGreaterThanOrEqual(v.count, 2, "dither spreads the value over neighbouring levels")
        XCTAssertTrue(v.isSubset(of: Set(126...129)), "and never by more than a level or two: \(v.sorted())")
        let mean = Double(dithered.px.enumerated().filter { $0.offset % 4 == 0 }.map { Int($0.element) }.reduce(0, +)) / Double(dithered.w * dithered.h)
        XCTAssertEqual(mean, 127.5, accuracy: 0.3, "the average is the true value")

        let transparent = try decodePNG(try PNGExporter.export(doc))
        XCTAssertEqual(pixel(transparent, 50, 50)[3], 128, accuracy: 1)
        XCTAssertEqual(pixel(transparent, 50, 50)[0], 0, "premultiplied black stays black")
    }

    func testTallImagesHaveNoSeamsBetweenBands() throws {
        // 50.8 x 254 mm at 300 DPI is 600 x 3000 pixels, drawn in 256-row bands.
        let doc = Document(size: Size2(50.8, 254), dpi: 300, layers: [rect("bar", Rect2(x: 0, y: 10, width: 50.8, height: 230), RGBA(0.2, 0.4, 0.8))])
        let png = try decodePNG(try PNGExporter.export(doc, dither: false))
        XCTAssertEqual(png.h, 3000)
        let first = pixel(png, 300, 300)
        for y in stride(from: 250, to: 3000, by: 256) { for dy in -3...3 where y + dy < 2800 {
            XCTAssertEqual(pixel(png, 300, y + dy), first, "row \(y + dy)")
        } }
        let top = (0..<3000).first { pixel(png, 300, $0)[3] == 255 }
        XCTAssertEqual(top, 119, "10 mm is 118.1 pixels, so row 118 is partly covered and 119 is the first solid row, whichever band it lands in")
    }

    func testPicturesAreIncluded() throws {
        let assets = TestAssets()
        assets.images["p"] = solidImage(4, 4, r: 0, g: 200, b: 0)
        let layer = Layer(name: "pic", content: .image(ImageContent(assetID: "p", size: Size2(5.08, 5.08))), transform: .translation(2.54, 2.54))
        let doc = Document(size: Size2(10.16, 10.16), dpi: 300, layers: [layer])
        let png = try decodePNG(try PNGExporter.export(doc, assets: assets, dither: false))
        XCTAssertEqual(pixel(png, 60, 60), [0, 200, 0, 255])
    }

    func testHugeImagesAreRefused() {
        let doc = Document(size: Size2(5000, 5000), dpi: 300)
        XCTAssertThrowsError(try PNGExporter.export(doc, dpi: 1200)) { error in
            guard case PNGExportError.tooLarge = error else { return XCTFail("\(error)") }
        }
    }
}

final class ColourTests: XCTestCase {
    private func converter() throws -> SystemCMYKConverter { try XCTUnwrap(SystemCMYKConverter()) }

    func testWhiteBlackAndRed() throws {
        let c = try converter()
        let white = c.cmyk(from: .white)
        XCTAssertLessThan(max(white.c, white.m, white.y, white.k), 0.03, "paper white needs no ink")
        XCTAssertGreaterThan(c.cmyk(from: .black).k, 0.7)
        let red = c.cmyk(from: RGBA(1, 0, 0))
        XCTAssertGreaterThan(red.m, 0.5); XCTAssertGreaterThan(red.y, 0.5); XCTAssertLessThan(red.c, 0.25)
    }

    func testProfileIsAvailableForTheOutputIntent() throws {
        let c = try converter()
        XCTAssertGreaterThan(c.profile.count, 1000)
        XCTAssertFalse(c.conditionName.isEmpty)
        XCTAssertNil(SystemCMYKConverter(iccProfile: Data("not a profile".utf8)))
        let again = try XCTUnwrap(SystemCMYKConverter(iccProfile: c.profile, name: "My shop"))
        XCTAssertEqual(again.conditionName, "My shop")
        XCTAssertEqual(again.cmyk(from: RGBA(1, 0, 0)).m, c.cmyk(from: RGBA(1, 0, 0)).m, accuracy: 0.01, "the same profile gives the same ink")
    }

    func testGamut() throws {
        let c = try converter()
        XCTAssertFalse(c.isInGamut(RGBA(0, 1, 0)), "pure screen green cannot be printed")
        XCTAssertFalse(c.isInGamut(RGBA(0, 0.9, 1)))
        XCTAssertTrue(c.isInGamut(RGBA(0.5, 0.5, 0.5)))
        XCTAssertTrue(c.isInGamut(.white))
        let near = c.nearestInGamut(RGBA(0, 1, 0, 0.5))
        XCTAssertLessThan(near.g, 0.95, "the printable green is duller")
        XCTAssertEqual(near.a, 0.5, "alpha is not touched")
        XCTAssertTrue(c.isInGamut(near), "the nearest colour is itself printable")
    }

    func testPictureConversionKeepsAlphaAndMapsWhiteToNoInk() throws {
        let c = try converter()
        let img = RGBAImage(width: 2, height: 1, pixels: [255, 255, 255, 255, 255, 0, 0, 64])
        let out = c.cmykPixels(img)
        XCTAssertEqual(out.count, 10)
        XCTAssertLessThan(Int(out[0]) + Int(out[1]) + Int(out[2]) + Int(out[3]), 20, "white picture pixel: no ink")
        XCTAssertEqual(out[4], 255); XCTAssertEqual(out[9], 64, "alpha passes through")
        XCTAssertGreaterThan(out[6], 100); XCTAssertGreaterThan(out[7], 100)        // red: magenta and yellow
    }

    func testSoftProofDullsOutOfGamutColoursAndLeavesGreysAlone() throws {
        let c = try converter()
        let img = RGBAImage(width: 2, height: 1, pixels: [0, 255, 0, 255, 128, 128, 128, 255])
        let proof = c.softProof(img)
        XCTAssertLessThan(Int(proof.pixels[1]), 235, "neon green is duller when printed")
        XCTAssertEqual(Int(proof.pixels[4]), 128, accuracy: 8)
        XCTAssertEqual(Int(proof.pixels[3]), 255); XCTAssertEqual(Int(proof.pixels[7]), 255)
    }

    func testPreflightUsesTheRealGamut() throws {
        let c = try converter()
        var doc = ProductCatalog.tshirtFront.makeDocument()
        doc.layers = [rect("neon", Rect2(x: 50, y: 50, width: 100, height: 100), RGBA(0, 1, 0.1))]
        XCTAssertFalse(Preflight.run(doc, gamut: c).issues.filter { $0.check == .gamut }.isEmpty)
        XCTAssertTrue(Preflight.run(doc).issues.filter { $0.check == .gamut }.isEmpty)
    }
}

final class PipelineTests: XCTestCase {
    private func disc(_ r: Double, at c: Point, _ color: RGBA = .black) -> Layer {
        Layer(name: "disc", content: .shape(ShapeContent(path: .ellipse(in: Rect2(x: 0, y: 0, width: 2 * r, height: 2 * r)), fill: color)),
              transform: .translation(c.x - r, c.y - r))
    }

    private func stickerDocument() -> Document {
        var doc = ProductCatalog.dieCutSticker.makeDocument(title: "Cat sticker")
        doc.layers = [disc(30, at: Point(40.5, 40.5), RGBA(0.8, 0.3, 0.2))]
        return doc
    }

    func testCutLineIsTheOffsetOfTheArtwork() throws {
        let path = try CutLineBuilder.cutPath(for: stickerDocument())          // offset 2 mm around a 30 mm radius disc
        XCTAssertEqual(path.contours.count, 1)
        let b = try XCTUnwrap(path.bounds)
        XCTAssertEqual(b.min.x, 40.5 - 32, accuracy: 0.4)
        XCTAssertEqual(b.max.x, 40.5 + 32, accuracy: 0.4)
        XCTAssertEqual(b.min.y, 40.5 - 32, accuracy: 0.4)
        XCTAssertFalse(path.hasSelfIntersections())
    }

    func testStickerExportMakesEveryFileTheProductNeeds() throws {
        let files = try ExportPipeline().export(stickerDocument())
        XCTAssertEqual(files.map { $0.name }, ["Cat-sticker-cut.pdf", "Cat-sticker.png", "Cat-sticker.svg", "Cat-sticker-cut.dxf"])
        let byFormat = Dictionary(uniqueKeysWithValues: files.map { ($0.format, $0.data) })

        let pdf = String(decoding: try XCTUnwrap(byFormat[.pdfCutContour]), as: UTF8.self)
        XCTAssertTrue(pdf.contains("/CutContour")); XCTAssertTrue(pdf.contains("/GTS_PDFX"))
        let svg = String(decoding: try XCTUnwrap(byFormat[.svg]), as: UTF8.self)
        XCTAssertTrue(svg.contains("id=\"CutContour\""))
        let dxf = String(decoding: try XCTUnwrap(byFormat[.dxf]), as: UTF8.self)
        XCTAssertTrue(dxf.contains("POLYLINE")); XCTAssertTrue(dxf.hasSuffix("0\nEOF\n"))
        let png = try decodePNG(try XCTUnwrap(byFormat[.png]))
        XCTAssertEqual(png.w, 957)                       // 81 mm at 300 DPI
        XCTAssertEqual(png.px[(png.h / 2 * png.w + png.w / 2) * 4 + 3], 255)
        XCTAssertEqual(png.px[3], 0, "the corner is transparent")
    }

    func testArchiveHoldsTheFiles() throws {
        let zip = try ExportPipeline().exportArchive(stickerDocument())
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        let text = String(decoding: zip, as: UTF8.self)
        for name in ["Cat-sticker-cut.pdf", "Cat-sticker.png", "Cat-sticker.svg", "Cat-sticker-cut.dxf"] { XCTAssertTrue(text.contains(name), name) }
    }

    func testChosenFormatsAndTheCMYKFile() throws {
        let files = try ExportPipeline().export(stickerDocument(), options: ExportOptions(formats: [.cmykPDF, .svg]))
        XCTAssertEqual(files.map { $0.format }, [.cmykPDF, .svg])
        let pdf = String(decoding: files[0].data, as: UTF8.self)
        XCTAssertTrue(pdf.contains("/DeviceCMYK"))
        XCTAssertTrue(pdf.contains("Generic CMYK Profile"))
    }

    func testProblemsBlockTheExportUnlessOverridden() throws {
        let assets = TestAssets()
        assets.images["tiny"] = solidImage(10, 10, r: 10, g: 20, b: 30)
        var doc = ProductCatalog.tshirtFront.makeDocument(title: "Tee")
        doc.layers = [Layer(name: "photo", content: .image(ImageContent(assetID: "tiny", size: Size2(150, 150), pixelWidth: 10, pixelHeight: 10)),
                            transform: .translation(50, 50))]
        let pipeline = ExportPipeline(assets: assets)
        XCTAssertThrowsError(try pipeline.export(doc, options: ExportOptions(formats: [.pdfX4]))) { error in
            guard case ExportError.blocked(let report) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(report.errors, 1)
            XCTAssertTrue("\(error)".contains("low resolution"))
        }
        XCTAssertNoThrow(try pipeline.export(doc, options: ExportOptions(formats: [.pdfX4], ignorePreflightErrors: true)))
    }

    func testCutFormatsNeedCutSettings() {
        var doc = ProductCatalog.tshirtFront.makeDocument()
        doc.layers = [disc(50, at: Point(150, 150))]
        XCTAssertThrowsError(try ExportPipeline().export(doc, options: ExportOptions(formats: [.dxf]))) { error in
            guard case ExportError.noCutLine = error else { return XCTFail("\(error)") }
        }
    }

    func testMugGetsAFlatWhiteBackgroundPNG() throws {
        var doc = ProductCatalog.mug11.makeDocument(title: "Mug")
        doc.layers = [rect("bg", Rect2(x: 0, y: 0, width: doc.size.width, height: doc.size.height), RGBA(0.2, 0.4, 0.8))]
        let files = try ExportPipeline().export(doc, options: ExportOptions(formats: [.png]))
        let png = try decodePNG(files[0].data)
        XCTAssertEqual(png.px[3], 255)
    }

    func testPreflightThroughThePipeline() throws {
        var doc = ProductCatalog.tshirtFront.makeDocument()
        doc.layers = [rect("neon", Rect2(x: 50, y: 50, width: 100, height: 100), RGBA(0, 1, 0.1))]
        let report = ExportPipeline().preflight(doc)
        XCTAssertTrue(report.issues.contains { $0.check == .gamut })
    }

    func testFileNames() {
        XCTAssertEqual(ExportPipeline.baseName("Café crème — été!"), "Café-crème-été")
        XCTAssertEqual(ExportPipeline.baseName("مرحبا بكم"), "مرحبا-بكم")
        XCTAssertEqual(ExportPipeline.baseName("   "), "design")
        XCTAssertEqual(ExportPipeline.baseName("a/b\\c:d"), "a-b-c-d")
    }

    func testCMYKAndRGBPDFsLookTheSameOnScreen() throws {
        var doc = ProductCatalog.tshirtFront.makeDocument(title: "Colours")
        doc.size = Size2(60, 40)
        doc.layers = [
            rect("brown", Rect2(x: 2, y: 2, width: 16, height: 16), RGBA(0.55, 0.3, 0.2)),
            rect("grey", Rect2(x: 22, y: 2, width: 16, height: 16), RGBA(0.5, 0.5, 0.5)),
            rect("sky", Rect2(x: 42, y: 2, width: 16, height: 16), RGBA(0.55, 0.7, 0.9)),
            rect("wine", Rect2(x: 2, y: 22, width: 16, height: 16), RGBA(0.5, 0.1, 0.2)),
            rect("half", Rect2(x: 22, y: 22, width: 16, height: 16), RGBA(0.2, 0.2, 0.2), opacity: 0.5),
        ]
        let files = try ExportPipeline().export(doc, preset: ProductCatalog.tshirtFront, options: ExportOptions(formats: [.pdfX4, .cmykPDF], ignorePreflightErrors: true))
        func render(_ data: Data) throws -> [UInt8] {
            let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
            let pdf = try XCTUnwrap(CGPDFDocument(provider)), page = try XCTUnwrap(pdf.page(at: 1))
            let w = 600, h = 400
            var px = [UInt8](repeating: 255, count: w * h * 4)
            px.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                let box = page.getBoxRect(.mediaBox)
                ctx.scaleBy(x: CGFloat(w) / box.width, y: CGFloat(h) / box.height)
                ctx.drawPDFPage(page)
            }
            return px
        }
        let rgb = try render(files[0].data), cmyk = try render(files[1].data)
        var worst = 0
        for (x, y) in [(100, 100), (300, 100), (500, 100), (100, 300), (300, 300)] {
            let o = (y * 600 + x) * 4
            let d = (0..<3).map { abs(Int(rgb[o + $0]) - Int(cmyk[o + $0])) }.max()!
            worst = max(worst, d)
        }
        XCTAssertLessThan(worst, 30, "the CMYK file shows the same colours as the RGB one, within what CMYK can print")
    }
}
#endif
