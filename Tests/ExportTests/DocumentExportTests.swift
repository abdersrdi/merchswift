import XCTest
import CutLine
import DocumentModel
import Products
@testable import Export

private final class Pixels: PixelSource {
    var images: [String: RGBAImage] = [:]
    func pixels(for assetID: String) -> RGBAImage? { images[assetID] }
}

final class DocumentExportTests: XCTestCase {
    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("merchswift-\(UUID().uuidString)-\(name)")
    }

    private func rect(_ name: String, _ r: Rect2, _ fill: RGBA, opacity: Double = 1, blend: BlendMode = .normal) -> Layer {
        Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: r.width, height: r.height)), fill: fill)),
              transform: .translation(r.x, r.y), opacity: opacity, blendMode: blend)
    }

    /// The document the CI render check and the structure tests share: 100 x 60 mm.
    static func sampleDocument() -> (Document, Pixels) {
        let pixels = Pixels()
        // Two pixels: opaque magenta on the left, fully transparent on the right.
        pixels.images["half"] = RGBAImage(width: 2, height: 1, pixels: [255, 0, 255, 255, 0, 255, 0, 0])
        func shape(_ name: String, _ r: Rect2, _ c: RGBA, opacity: Double = 1, blend: BlendMode = .normal) -> Layer {
            Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: r.width, height: r.height)), fill: c)),
                  transform: .translation(r.x, r.y), opacity: opacity, blendMode: blend)
        }
        let layers: [Layer] = [
            shape("red", Rect2(x: 10, y: 10, width: 30, height: 20), RGBA(1, 0, 0)),
            shape("half green", Rect2(x: 60, y: 10, width: 30, height: 20), RGBA(0, 1, 0), opacity: 0.5),
            shape("multiply", Rect2(x: 20, y: 20, width: 30, height: 20), RGBA(0.5, 0.5, 1), blend: .multiply),
            Layer(name: "picture", content: .image(ImageContent(assetID: "half", size: Size2(20, 10), pixelWidth: 2, pixelHeight: 1)),
                  transform: .translation(70, 40)),
            Layer(name: "ring", content: .shape(ShapeContent(path: .ellipse(in: Rect2(x: 0, y: 0, width: 20, height: 20)), fill: nil,
                                                              stroke: Stroke(color: RGBA(0, 0, 1), width: 2))),
                  transform: .translation(10, 35)),
        ]
        return (Document(title: "Sample", size: Size2(100, 60), dpi: 300, layers: layers), pixels)
    }

    // MARK: PDF content

    func testContentStreamForSimpleShapes() {
        let doc = Document(size: Size2(50, 50), layers: [
            rect("a", Rect2(x: 5, y: 6, width: 10, height: 20), RGBA(1, 0.5, 0)),
        ])
        let expected = """
        == page
        q 1 0 0 1 5 6 cm
        0 0 m
        10 0 l
        10 20 l
        0 20 l
        h
        /CS0 cs 1 0.5 0 sc
        f
        Q

        """
        XCTAssertEqual(PDFDescription.describe(doc), expected)
    }

    func testOpacityAndBlendUseTransparencyGroups() {
        let doc = Document(size: Size2(50, 50), layers: [rect("a", Rect2(x: 0, y: 0, width: 10, height: 10), .black, opacity: 0.5, blend: .multiply)])
        let text = PDFDescription.describe(doc)
        XCTAssertTrue(text.contains("/GS1 gs /Fm1 Do"))
        XCTAssertTrue(text.contains("-- state GS1 ca=0.5 CA=0.5 blend=Multiply"))
        XCTAssertTrue(text.contains("-- form Fm1 bbox=[-2 -2 12 12]"))
        XCTAssertTrue(text.contains("== Fm1"), "the group's own content follows")
    }

    func testStrokeAndHiddenLayersAndTransforms() {
        var hidden = rect("h", Rect2(x: 0, y: 0, width: 5, height: 5), .black)
        hidden.isVisible = false
        let ring = Layer(name: "r", content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: 4, height: 4)), fill: RGBA(1, 0, 0), stroke: Stroke(color: RGBA(0, 0, 1), width: 0.5))),
                         transform: Transform2D.scale(2, 2).then(.translation(1, 1)))
        let text = PDFDescription.describe(Document(size: Size2(20, 20), layers: [hidden, ring]))
        XCTAssertFalse(text.contains("0 0 0 sc"), "hidden layers are not drawn")
        XCTAssertTrue(text.contains("q 2 0 0 2 1 1 cm"))
        XCTAssertTrue(text.contains("/CS0 CS 0 0 1 SC 0.5 w 1 J 1 j"))
        XCTAssertTrue(text.contains("\nB\n"), "fill and stroke together")
    }

    func testSemiTransparentColoursGetTheirOwnState() {
        let l = Layer(name: "s", content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: 4, height: 4)), fill: RGBA(1, 0, 0, 0.25), stroke: Stroke(color: RGBA(0, 0, 0, 0.75), width: 1))))
        let text = PDFDescription.describe(Document(size: Size2(10, 10), layers: [l]))
        XCTAssertTrue(text.contains("-- state GS1 ca=0.25 CA=0.75 blend=Normal"), text)
    }

    func testImagesAreFlippedUpright() {
        let l = Layer(name: "i", content: .image(ImageContent(assetID: "pic", size: Size2(30, 12))), transform: .translation(5, 5))
        let text = PDFDescription.describe(Document(size: Size2(50, 50), layers: [l]))
        XCTAssertTrue(text.contains("q 30 0 0 -12 0 12 cm /Im1 Do Q"))
        XCTAssertTrue(text.contains("-- image Im1 = pic"))
    }

    func testGroupsNestTheirTransforms() {
        let inner = rect("in", Rect2(x: 2, y: 2, width: 4, height: 4), .black)
        let g = Layer(name: "g", content: .group([inner]), transform: .translation(10, 10))
        let text = PDFDescription.describe(Document(size: Size2(30, 30), layers: [g]))
        XCTAssertTrue(text.hasPrefix("== page\nq 1 0 0 1 10 10 cm\nq 1 0 0 1 2 2 cm\n"), text)
    }

    func testTextIsDrawnAsItsOutline() {
        let t = Layer(name: "t", content: .text(TextContent(text: "A", style: TextStyle(fill: RGBA(0, 0, 0)),
                                                              outline: PathData(elements: [.move(Point(0, 0)), .line(Point(1, 0)), .line(Point(0, 1)), .close]))))
        let text = PDFDescription.describe(Document(size: Size2(10, 10), layers: [t]))
        XCTAssertTrue(text.contains("0 0 m\n1 0 l\n0 1 l\nh\n/CS0 cs 0 0 0 sc\nf"))
    }

    func testNumbersAreCompactAndStable() {
        XCTAssertEqual(PDFContentBuilder.num(0), "0")
        XCTAssertEqual(PDFContentBuilder.num(1.500000), "1.5")
        XCTAssertEqual(PDFContentBuilder.num(-0.0000001), "0")
        XCTAssertEqual(PDFContentBuilder.num(12.345678), "12.34568")
        XCTAssertEqual(PDFContentBuilder.num(100), "100")
    }

    // MARK: PDF file

    func testWritesAValidPDFWithTransparencyAndImages() throws {
        let (doc, pixels) = Self.sampleDocument()
        let url = tmp("sample.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let cut = CutPath(contours: [Contour(segments: [CubicBezier(Point(5, 5), Point(40, 5), Point(60, 5), Point(95, 5)),
                                                         CubicBezier(Point(95, 5), Point(95, 20), Point(95, 40), Point(95, 55)),
                                                         CubicBezier(Point(95, 55), Point(60, 55), Point(40, 55), Point(5, 55)),
                                                         CubicBezier(Point(5, 55), Point(5, 40), Point(5, 20), Point(5, 5))])])
        try DocumentPDF.write(doc, assets: pixels, to: url, options: DocumentPDFOptions(title: "Sample", trim: Rect2(x: 3, y: 3, width: 94, height: 54), cutLine: cut))

        let info = try StickerPDF.inspect(url)
        XCTAssertEqual(info.pageCount, 1)
        XCTAssertEqual(info.version, "1.6")

        let raw = try Data(contentsOf: url)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("%PDF-1.6"))
        XCTAssertTrue(text.hasSuffix("\n%%EOF\n"))
        XCTAssertTrue(text.contains("/GTS_PDFX"))
        XCTAssertTrue(text.contains("pdfxid:GTS_PDFXVersion=\"PDF/X-4\""))
        XCTAssertTrue(text.contains("/Separation"))
        XCTAssertTrue(text.contains("/CutContour"))
        XCTAssertNotNil(text.range(of: #"/BM\s*/Multiply"#, options: .regularExpression), "the multiply blend is a real PDF blend mode")
        XCTAssertNotNil(text.range(of: #"/Subtype\s*/Form"#, options: .regularExpression))
        XCTAssertNotNil(text.range(of: #"/S\s*/Transparency"#, options: .regularExpression))
        XCTAssertNotNil(text.range(of: #"/SMask"#, options: .regularExpression), "the image keeps its alpha")
        // 100 x 60 mm in points.
        XCTAssertNotNil(text.range(of: #"/MediaBox\s*\[\s*0 0 283\.46[0-9]* 170\.07[0-9]*\s*\]"#, options: .regularExpression))
        XCTAssertNotNil(text.range(of: #"/TrimBox\s*\["#, options: .regularExpression))
    }

    func testPDFWithoutImagesOrCutLine() throws {
        let doc = Document(size: Size2(40, 40), layers: [rect("a", Rect2(x: 5, y: 5, width: 10, height: 10), RGBA(0.2, 0.4, 0.6))])
        let url = tmp("plain.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentPDF.write(doc, to: url)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains("/CutContour"))
        XCTAssertEqual(try StickerPDF.inspect(url).pageCount, 1)
    }

    func testMissingImagePixelsDoNotBreakTheFile() throws {
        let doc = Document(size: Size2(40, 40), layers: [Layer(name: "i", content: .image(ImageContent(assetID: "gone", size: Size2(10, 10))))])
        let url = tmp("missing.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try DocumentPDF.write(doc, assets: Pixels(), to: url))
    }

    func testSameImageUsedTwiceIsEmbeddedOnce() throws {
        let pixels = Pixels()
        pixels.images["p"] = RGBAImage(width: 1, height: 1, pixels: [10, 20, 30, 255])
        let a = Layer(name: "a", content: .image(ImageContent(assetID: "p", size: Size2(5, 5))))
        let b = Layer(name: "b", content: .image(ImageContent(assetID: "p", size: Size2(5, 5))), transform: .translation(10, 0))
        let url = tmp("twice.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentPDF.write(Document(size: Size2(30, 30), layers: [a, b]), assets: pixels, to: url)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let images = try NSRegularExpression(pattern: #"/Subtype\s*/Image"#).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertEqual(images, 2, "one picture and its alpha mask, not two copies")
    }

    // MARK: SVG

    func testSVGOfTheSampleDocument() {
        let (doc, _) = Self.sampleDocument()
        let svg = DocumentSVG.svg(doc)
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains("viewBox=\"0 0 100 60\""))
        XCTAssertTrue(svg.contains("<path id=\"red\" transform=\"matrix(1 0 0 1 10 10)\" fill=\"#ff0000\" d=\"M0 0L30 0L30 20L0 20Z\"/>"), svg)
        XCTAssertTrue(svg.contains("opacity=\"0.5\""))
        XCTAssertTrue(svg.contains("mix-blend-mode:multiply"))
        XCTAssertTrue(svg.contains("stroke=\"#0000ff\" stroke-width=\"2\""))
        XCTAssertTrue(svg.contains("<image id=\"picture\""))
    }

    func testSVGEmbedsImagesAndTheCutLine() {
        let (doc, pixels) = Self.sampleDocument()
        let cut = CutPath(contours: [Contour(segments: [CubicBezier(Point(0, 0), Point(1, 0), Point(2, 1), Point(3, 1))])])
        let svg = DocumentSVG.svg(doc, assets: pixels, cutLine: cut)
        XCTAssertTrue(svg.contains("xlink:href=\"data:image/png;base64,iVBOR"))
        XCTAssertTrue(svg.contains("<path id=\"CutContour\""))
    }

    func testSVGEscapesLayerNames() {
        let l = rect("a \"b\" <c> & d", Rect2(x: 0, y: 0, width: 1, height: 1), .black)
        XCTAssertTrue(DocumentSVG.svg(Document(size: Size2(5, 5), layers: [l])).contains("id=\"a &quot;b&quot; &lt;c&gt; &amp; d\""))
    }

    // MARK: PNG and ZIP

    func testPNGRoundTrip() throws {
        let img = RGBAImage(width: 3, height: 2, pixels: [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0,
                                                          1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        let png = PNGEncoder.encode(img, dpi: 300)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let decoded = try MiniPNG.decode(png)
        XCTAssertEqual(decoded.width, 3); XCTAssertEqual(decoded.height, 2)
        XCTAssertEqual(decoded.pixels, img.pixels)
        XCTAssertEqual(decoded.pixelsPerMetre, 11811, "300 DPI is 11811 pixels per metre")
    }

    func testLargePNGSpansSeveralStoredBlocks() throws {
        var px = [UInt8](repeating: 0, count: 300 * 300 * 4)
        for i in 0..<px.count { px[i] = UInt8(truncatingIfNeeded: i &* 7) }
        let img = RGBAImage(width: 300, height: 300, pixels: px)
        let decoded = try MiniPNG.decode(PNGEncoder.encode(img))
        XCTAssertEqual(decoded.pixels, px)
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF43926)
    }

    func testZipArchiveIsReadable() throws {
        var zip = ZipWriter()
        zip.add(name: "design.pdf", data: Data("%PDF fake".utf8))
        zip.add(name: "folder/نص.svg", data: Data("<svg/>".utf8))
        zip.add(name: "empty.txt", data: Data())
        let bytes = zip.data()
        let entries = try MiniZip.read(bytes)
        XCTAssertEqual(entries.map { $0.name }, ["design.pdf", "folder/نص.svg", "empty.txt"])
        XCTAssertEqual(entries[0].data, Data("%PDF fake".utf8))
        XCTAssertEqual(entries[1].data, Data("<svg/>".utf8))
        XCTAssertEqual(entries[2].data.count, 0)
        XCTAssertEqual(zip.data(), bytes, "the same files always give the same archive")
    }

    // MARK: Proof files for the CI render check

    func testWriteProofFiles() throws {
        guard let dir = ProcessInfo.processInfo.environment["MERCHSWIFT_PROOF_DIR"] else { throw XCTSkip("no proof dir") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (doc, pixels) = Self.sampleDocument()
        try DocumentPDF.write(doc, assets: pixels, to: out.appendingPathComponent("document-sample.pdf"),
                              options: DocumentPDFOptions(title: "Sample"))
        try DocumentSVG.svg(doc, assets: pixels).write(to: out.appendingPathComponent("document-sample.svg"), atomically: true, encoding: .utf8)
        try PNGEncoder.encode(RGBAImage(width: 4, height: 2, pixels: (0..<8).flatMap { [UInt8($0 * 30), 100, 200, 255] }), dpi: 300)
            .write(to: out.appendingPathComponent("encoder-sample.png"))
        var zip = ZipWriter()
        zip.add(name: "a.txt", data: Data("hello".utf8))
        zip.add(name: "b/c.txt", data: Data("world".utf8))
        try zip.data().write(to: out.appendingPathComponent("zip-sample.zip"))
    }
}

// MARK: Small readers used only by the tests

enum MiniPNG {
    struct Image { var width: Int; var height: Int; var pixels: [UInt8]; var pixelsPerMetre: Int? }

    static func decode(_ data: Data) throws -> Image {
        let b = [UInt8](data)
        func be32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        var i = 8
        var w = 0, h = 0, ppm: Int?
        var z: [UInt8] = []
        while i + 8 <= b.count {
            let len = be32(i)
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            let body = Array(b[(i + 8)..<(i + 8 + len)])
            let crc = UInt32(be32(i + 8 + len) & 0xFFFFFFFF)
            XCTAssertEqual(crc, CRC32.checksum(Array(b[(i + 4)..<(i + 8)]) + body), "chunk \(type) checksum")
            switch type {
            case "IHDR": w = Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3]); h = Int(body[4]) << 24 | Int(body[5]) << 16 | Int(body[6]) << 8 | Int(body[7])
            case "pHYs": ppm = Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
            case "IDAT": z += body
            default: break
            }
            i += 12 + len
        }
        // Undo the stored blocks.
        var raw: [UInt8] = []
        var p = 2
        while p < z.count - 4 {
            let final = z[p] & 1 == 1
            let n = Int(z[p + 1]) | Int(z[p + 2]) << 8
            raw += z[(p + 5)..<(p + 5 + n)]
            p += 5 + n
            if final { break }
        }
        var px: [UInt8] = []
        for y in 0..<h {
            let row = y * (w * 4 + 1)
            XCTAssertEqual(raw[row], 0)
            px += raw[(row + 1)..<(row + 1 + w * 4)]
        }
        return Image(width: w, height: h, pixels: px, pixelsPerMetre: ppm)
    }
}

enum MiniZip {
    struct Entry { var name: String; var data: Data }

    static func read(_ data: Data) throws -> [Entry] {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        // End of central directory is the last 22 bytes (no comment).
        let end = b.count - 22
        XCTAssertEqual(u32(end), 0x06054B50)
        let count = u16(end + 10)
        var p = u32(end + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            XCTAssertEqual(u32(p), 0x02014B50)
            let crc = u32(p + 16), size = u32(p + 24)
            let nameLen = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32)
            let offset = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            XCTAssertEqual(u32(offset), 0x04034B50)
            let lNameLen = u16(offset + 26), lExtra = u16(offset + 28)
            let start = offset + 30 + lNameLen + lExtra
            let body = Array(b[start..<(start + size)])
            XCTAssertEqual(UInt32(crc), CRC32.checksum(body), "\(name) checksum")
            out.append(Entry(name: name, data: Data(body)))
            p += 46 + nameLen + extra + comment
        }
        return out
    }
}
