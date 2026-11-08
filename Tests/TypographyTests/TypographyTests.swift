#if canImport(CoreText) && canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import CoreText
import CutLine
import DocumentModel
import Editor
import ImageIO
import Renderer
import XCTest
@testable import Typography

private func halfToFloat(_ h: UInt16) -> Float {
    let sign: Float = (h >> 15) & 1 == 1 ? -1 : 1
    let e = Int((h >> 10) & 0x1f), m = Float(h & 0x3ff)
    if e == 0 { return sign * m * Float(pow(2.0, -24.0)) }
    if e == 31 { return m == 0 ? sign * .infinity : .nan }
    return sign * (1 + m / 1024) * Float(pow(2.0, Double(e - 15)))
}

final class TypographyTests: XCTestCase {
    let shaper = CoreTextShaper()

    override func setUp() {
        super.setUp()
        FontLibrary.shared.registerBundledFonts()
    }

    private func style(_ family: String = "Cairo", size: Double = 20, weight: Double = 400, _ configure: (inout TextStyle) -> Void = { _ in }) -> TextStyle {
        var s = TextStyle(family: family, weight: weight, size: size)
        configure(&s)
        return s
    }

    private func shaped(_ text: String, _ s: TextStyle, box: Double? = nil) -> ShapedText { shaper.shape(text: text, style: s, boxWidth: box) }

    // MARK: Fonts

    func testBundledFamiliesAreRegistered() {
        let names = Set(FontLibrary.shared.families.map { $0.name })
        for expected in ["Cairo", "Tajawal", "Amiri", "Reem Kufi", "El Messiri", "Noto Kufi Arabic", "Noto Naskh Arabic",
                         "Playfair Display", "Montserrat", "Bebas Neue", "Lobster", "Pacifico"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected); registered: \(names.sorted())")
        }
    }

    func testArabicSupportIsReportedPerFamily() {
        let byName = Dictionary(uniqueKeysWithValues: FontLibrary.shared.families.map { ($0.name, $0) })
        for arabic in ["Cairo", "Tajawal", "Amiri", "Reem Kufi", "El Messiri", "Noto Kufi Arabic", "Noto Naskh Arabic"] {
            XCTAssertEqual(byName[arabic]?.supportsArabic, true, arabic)
        }
        for latin in ["Montserrat", "Bebas Neue", "Lobster", "Pacifico", "Playfair Display"] {
            XCTAssertEqual(byName[latin]?.supportsArabic, false, latin)
        }
        XCTAssertTrue(byName["Cairo"]?.isBundled == true)
    }

    func testImportingAFontFileRegistersIt() throws {
        let url = try XCTUnwrap(FontLibrary.shared.bundledFontFiles.first { $0.lastPathComponent == "BebasNeue-Regular.ttf" })
        let names = try FontLibrary.shared.register(fontAt: url)
        XCTAssertEqual(names, ["Bebas Neue"])
        XCTAssertNoThrow(try FontLibrary.shared.register(fontAt: url), "registering twice is harmless")
    }

    func testVariableWeightChangesTheLetters() {
        let light = shaped("Cairo", style("Cairo", weight: 300)), black = shaped("Cairo", style("Cairo", weight: 900))
        XCTAssertGreaterThan(black.size.width, light.size.width + 1, "a heavier weight is wider")
        XCTAssertNotEqual(light.outline, black.outline)
    }

    func testStaticFamiliesPickTheNearestStyle() {
        let regular = shaped("Tajawal", style("Tajawal", weight: 400)), bold = shaped("Tajawal", style("Tajawal", weight: 700))
        XCTAssertNotEqual(regular.outline, bold.outline)
        let upright = shaped("Amiri", style("Amiri"))
        let italic = shaped("Amiri", style("Amiri") { $0.italic = true })
        XCTAssertNotEqual(upright.outline, italic.outline)
    }

    func testFontSizeIsInMillimetres() {
        let small = shaped("H", style("Montserrat", size: 10)), big = shaped("H", style("Montserrat", size: 40))
        XCTAssertEqual(big.size.width / small.size.width, 4, accuracy: 0.01)
        // A capital H is about 0.7 em tall.
        let h = big.outline.bounds!.height
        XCTAssertEqual(h, 40 * 0.7, accuracy: 4)
    }

    // MARK: Arabic

    func testArabicLettersJoin() {
        for family in ["Cairo", "Amiri", "Tajawal"] {
            let s = style(family, size: 40)
            let one = shaped("ب", s).size.width
            let two = shaped("بب", s).size.width
            XCTAssertLessThan(two, 2 * one - 1, "\(family): joined letters take less room than two isolated ones")
        }
    }

    func testLamAlefIsShapedAsAJoinedPair() {
        // Some fonts (Cairo, Tajawal) draw lam-alef as one ligature glyph; others (Amiri, Noto Naskh) build it from
        // two joined glyphs. Either way it must not be two separate isolated letters.
        for family in ["Cairo", "Tajawal"] {
            XCTAssertEqual(shaper.glyphCount(text: "لا", style: style(family, size: 40)), 1, "\(family) forms a single lam-alef glyph")
        }
        for family in ["Cairo", "Tajawal", "Amiri", "Noto Naskh Arabic"] {
            let s = style(family, size: 40)
            let together = shaped("لا", s).size.width
            let apart = shaped("ل", s).size.width + shaped("ا", s).size.width
            XCTAssertLessThan(together, apart - 0.5, "\(family): lam-alef takes less room than the two isolated letters")
        }
        XCTAssertEqual(shaper.glyphCount(text: "ل ا", style: style("Amiri", size: 40)), 3, "with a space between them there is no ligature")
    }

    func testDiacriticsAddHeightAndDepth() {
        let s = style("Amiri", size: 40)
        let plain = shaped("مرحبا", s).outline.bounds!
        let marked = shaped("مَرْحَبًا", s).outline.bounds!
        XCTAssertGreaterThan(marked.height, plain.height + 2)
    }

    func testDirectionFollowsTheFirstStrongLetterOrTheSetting() {
        let s = style("Cairo", size: 30)
        // "A ب": Latin first, so the paragraph runs left to right and the Latin letter sits on the left.
        let ltr = shaper.debugRuns(text: "A ب", style: s)
        let a = try? XCTUnwrap(ltr.first { $0.range.location == 0 })
        let arabic = try? XCTUnwrap(ltr.first { $0.range.location == 2 })
        XCTAssertLessThan(a?.x ?? 0, arabic?.x ?? 0)

        // Forcing right to left puts the first character on the right.
        let rtl = shaper.debugRuns(text: "A ب", style: style("Cairo", size: 30) { $0.direction = .rightToLeft })
        XCTAssertGreaterThan(rtl.first { $0.range.location == 0 }?.x ?? 0, rtl.first { $0.range.location == 2 }?.x ?? 1)

        // Arabic first: automatic direction is right to left.
        let auto = shaper.debugRuns(text: "ب A", style: s)
        XCTAssertGreaterThan(auto.first { $0.range.location == 0 }?.x ?? 0, auto.first { $0.range.location == 2 }?.x ?? 1)
    }

    func testArabicStartAlignmentIsOnTheRight() {
        let s = style("Amiri", size: 20)
        let arabic = shaped("مرحبا", s, box: 100).outline.bounds!
        XCTAssertEqual(arabic.maxX, 100, accuracy: 3, "Arabic starts on the right")
        let latin = shaped("Hello", style("Montserrat", size: 20), box: 100).outline.bounds!
        XCTAssertEqual(latin.minX, 0, accuracy: 3)
        let centred = shaped("Hello", style("Montserrat", size: 20) { $0.alignment = .center }, box: 100).outline.bounds!
        XCTAssertEqual(centred.midX, 50, accuracy: 2)
        let end = shaped("Hello", style("Montserrat", size: 20) { $0.alignment = .end }, box: 100).outline.bounds!
        XCTAssertEqual(end.maxX, 100, accuracy: 3)
    }

    func testMixedArabicAndFrenchInOneLine() {
        let s = style("Cairo", size: 24)
        let result = shaped("Star ستار – Café & Co. تجربة", s)
        XCTAssertGreaterThan(result.size.width, 100)
        XCTAssertGreaterThan(result.outline.closedSubpathCount, 15)
        XCTAssertFalse(result.outline.bounds!.width.isNaN)
        // Accents come out as real letters of the font, not missing-glyph boxes: "é" and "e" differ.
        XCTAssertNotEqual(shaped("é", s).outline, shaped("e", s).outline)
    }

    func testLetterSpacingSkipsArabic() {
        let arabicPlain = shaped("ستار", style("Cairo", size: 30)).size.width
        let arabicSpaced = shaped("ستار", style("Cairo", size: 30) { $0.tracking = 300 }).size.width
        XCTAssertEqual(arabicSpaced, arabicPlain, accuracy: 0.01, "Arabic must stay joined")
        let latinPlain = shaped("STAR", style("Montserrat", size: 30)).size.width
        let latinSpaced = shaped("STAR", style("Montserrat", size: 30) { $0.tracking = 300 }).size.width
        XCTAssertGreaterThan(latinSpaced, latinPlain + 3 * 0.3 * 30 - 1)
    }

    // MARK: OpenType features

    func testTabularFiguresChangeWidths() {
        let proportional = shaped("1111", style("Montserrat", size: 30)).size.width
        let tabular = shaped("1111", style("Montserrat", size: 30) { $0.features = [FontFeature("tnum")] }).size.width
        XCTAssertNotEqual(proportional, tabular, accuracy: 0.5)
    }

    func testSmallCapsFeature() {
        let normal = shaped("hello", style("Playfair Display", size: 40)).outline.bounds!
        let small = shaped("hello", style("Playfair Display", size: 40) { $0.features = [FontFeature("smcp")] }).outline.bounds!
        XCTAssertLessThan(small.height, normal.height - 3, "small caps have no ascenders")
    }

    // MARK: Lines

    func testWrappingAndLineSpacing() {
        let s = style("Montserrat", size: 10)
        let text = "The quick brown fox jumps over the lazy dog and keeps running"
        let one = shaped(text, s)
        let wrapped = shaped(text, s, box: 80)
        XCTAssertGreaterThan(wrapped.size.height, one.size.height * 2.5)
        XCTAssertLessThanOrEqual(wrapped.outline.bounds!.maxX, 80.5)
        XCTAssertEqual(wrapped.size.width, 80)

        let tight = shaped("a\nb\nc", s), loose = shaped("a\nb\nc", style("Montserrat", size: 10) { $0.lineSpacing = 2 })
        XCTAssertEqual(loose.size.height / tight.size.height, 2, accuracy: 0.01)
    }

    func testJustifiedTextFillsTheBox() {
        let s = style("Montserrat", size: 10) { $0.alignment = .justified }
        let r = shaped("The quick brown fox jumps over the lazy dog and keeps running", s, box: 80)
        XCTAssertEqual(r.outline.bounds!.width, 80, accuracy: 1.5)
    }

    func testEmptyAndWhitespaceText() {
        XCTAssertTrue(shaped("", style()).outline.elements.isEmpty)
        XCTAssertTrue(shaped("   ", style()).outline.elements.isEmpty)
        XCTAssertGreaterThan(shaped("", style()).size.height, 0, "an empty text layer still has a line height")
    }

    // MARK: Curves

    func testArcTextKeepsEveryLetterAndBends() {
        let flat = shaped("MERCH SWIFT", style("Bebas Neue", size: 30))
        let bent = shaped("MERCH SWIFT", style("Bebas Neue", size: 30) { $0.curve = .arc(degrees: 150) })
        XCTAssertEqual(bent.outline.closedSubpathCount, flat.outline.closedSubpathCount)
        XCTAssertGreaterThan(bent.outline.bounds!.height, flat.outline.bounds!.height * 2)
        XCTAssertEqual(bent.size, flat.size, "the layout block does not change, only the outline")
    }

    func testArabicOnAnArcStaysJoined() {
        let flat = shaped("رمضان كريم", style("Reem Kufi", size: 30))
        let bent = shaped("رمضان كريم", style("Reem Kufi", size: 30) { $0.curve = .arc(degrees: 120) })
        XCTAssertEqual(bent.outline.closedSubpathCount, flat.outline.closedSubpathCount, "no letter is lost or split")
    }

    // MARK: Drawing

    private func compose(_ doc: Document, level: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let density = TileGrid.pixelsPerMM(level: level)
        let w = Int((doc.size.width * density).rounded(.up)), h = Int((doc.size.height * density).rounded(.up))
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let n = TileGrid.tilePixels
        for key in TileGrid.visibleTiles(visible: doc.canvas, canvas: doc.canvas, level: level) {
            guard let tile = LayerRasterizer.render(doc, assets: nil, tile: key) else { continue }
            for ty in 0..<n {
                let y = key.y * n + ty
                if y >= h { break }
                for tx in 0..<n {
                    let x = key.x * n + tx
                    if x >= w { break }
                    let i = (ty * n + tx) * 4
                    let a = halfToFloat(tile.data[i + 3])
                    let o = (y * w + x) * 4
                    for c in 0..<3 {
                        let v = halfToFloat(tile.data[i + c]) + (1 - a)       // over white
                        out[o + c] = UInt8(max(0, min(255, (v * 255).rounded())))
                    }
                    out[o + 3] = 255
                }
            }
        }
        return (out, w, h)
    }

    private func writePNG(_ img: (pixels: [UInt8], width: Int, height: Int), name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MERCHSWIFT_PROOF_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var px = img.pixels
        let cg: CGImage? = px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let cg, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/" + name) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    private func textLayer(_ text: String, _ s: TextStyle, x: Double, y: Double, box: Double? = nil, name: String? = nil) -> Layer {
        var c = TextContent(text: text, style: s, boxWidth: box)
        c.reshape(using: shaper)
        return Layer(name: name ?? text, content: .text(c), transform: .translation(x, y))
    }

    func testCounterHolesStayOpen() throws {
        let doc = Document(size: Size2(60, 60), dpi: 300, layers: [textLayer("O", style("Montserrat", size: 50, weight: 700) { $0.fill = .black }, x: 5, y: 2)])
        let img = compose(doc, level: 3)     // 8 px per mm
        // The outline of the O is a ring: the centre is white, a point on the ring is black.
        let b = try XCTUnwrap(doc.worldBounds(of: doc.layers[0].id))
        let cx = Int(b.midX * 8), cy = Int(b.midY * 8)
        func lum(_ x: Int, _ y: Int) -> Int { Int(img.pixels[(y * img.width + x) * 4]) }
        XCTAssertGreaterThan(lum(cx, cy), 240, "the counter of the O is empty")
        let ringX = Int(b.minX * 8) + 6
        XCTAssertLessThan(lum(ringX, cy), 20, "the ring itself is filled")
    }

    func testTextRendersTheSameInPNGAndPDF() throws {
        let doc = Document(size: Size2(120, 44), dpi: 300, layers: [
            textLayer("مَرْحَبًا بكم", style("Amiri", size: 16), x: 4, y: 3, box: 112),
            textLayer("Café crème — été", style("Playfair Display", size: 12) { $0.alignment = .center }, x: 4, y: 24, box: 112),
        ])
        let level = 3
        let png = compose(doc, level: level)

        // The same drawing routine into a PDF page.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typo-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let ptPerMM = 72 / 25.4
        var box = CGRect(x: 0, y: 0, width: doc.size.width * ptPerMM, height: doc.size.height * ptPerMM)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.translateBy(x: 0, y: box.height)
        pdf.scaleBy(x: ptPerMM, y: -ptPerMM)
        LayerRasterizer.draw(doc, in: pdf, region: doc.canvas)
        pdf.endPDFPage()
        pdf.closePDF()

        // Text must be vector outlines: no font resources in the file.
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data("/FontFile".utf8)), "the PDF carries no embedded font, only outlines")
        XCTAssertNil(bytes.range(of: Data("/Type /Font".utf8)))

        // Render the PDF back to pixels at the PNG's density and compare.
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        var px = [UInt8](repeating: 255, count: png.width * png.height * 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: png.width, height: png.height, bitsPerComponent: 8, bytesPerRow: png.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: png.width, height: png.height))
            ctx.scaleBy(x: CGFloat(png.width) / box.width, y: CGFloat(png.height) / box.height)
            ctx.drawPDFPage(page)
        }
        var total = 0, big = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let d = abs(Int(px[i]) - Int(png.pixels[i]))
            total += d
            if d > 80 { big += 1 }
        }
        let mean = Double(total) / Double(png.width * png.height)
        XCTAssertLessThan(mean, 2.0, "mean difference between PDF and PNG renderings")
        XCTAssertLessThan(Double(big) / Double(png.width * png.height), 0.004, "at most 0.4% of pixels differ visibly (edge antialiasing)")
        writePNG(png, name: "typography-png-vs-pdf-png.png")
        writePNG((px, png.width, png.height), name: "typography-png-vs-pdf-pdf.png")
    }

    // MARK: Proof sheets (looked at by a person)

    func testWriteProofSheets() throws {
        guard ProcessInfo.processInfo.environment["MERCHSWIFT_PROOF_DIR"] != nil else { throw XCTSkip("no proof dir") }
        var layers: [Layer] = []
        var y = 4.0
        func add(_ text: String, _ s: TextStyle, box: Double = 232) {
            let l = textLayer(text, s, x: 4, y: y, box: box)
            layers.append(l)
            if case .text(let c) = l.content { y += c.size.height + 3 }
        }
        add("السلام عليكم ورحمة الله", style("Amiri", size: 15) { $0.alignment = .center })
        add("رمضان كريم", style("Reem Kufi", size: 17, weight: 600) { $0.alignment = .center; $0.fill = RGBA(0.08, 0.45, 0.35) })
        add("عيد مبارك سعيد", style("El Messiri", size: 15, weight: 700) { $0.alignment = .center })
        add("مرحبا بالعالم الجميل", style("Noto Kufi Arabic", size: 13, weight: 500) { $0.alignment = .center })
        add("بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ", style("Noto Naskh Arabic", size: 13) { $0.alignment = .center })
        add("Cairo خفيف ثقيل", style("Cairo", size: 13, weight: 900) { $0.alignment = .center })
        add("Star ستار — Café & Co. · Maroc المغرب", style("Cairo", size: 12, weight: 600) { $0.alignment = .center; $0.fill = RGBA(0.1, 0.1, 0.45) })
        add("Fête de l'Aïd — الاحتفال بعيد الفطر في الدار البيضاء", style("Tajawal", size: 10) { $0.alignment = .start })
        add("1234567890  ١٢٣٤٥٦٧٨٩٠", style("Montserrat", size: 11) { $0.features = [FontFeature("tnum")] ; $0.alignment = .center })
        let doc = Document(size: Size2(240, y + 4), dpi: 300, layers: layers)
        writePNG(compose(doc, level: 2), name: "typography-arabic-and-mixed.png")

        var curved: [Layer] = []
        curved.append(textLayer("رمضان كريم", style("Reem Kufi", size: 22, weight: 600) { $0.curve = .arc(degrees: 140); $0.alignment = .center }, x: 20, y: 24, box: 200))
        curved.append(textLayer("MERCH SWIFT · MADE TO PRINT", style("Bebas Neue", size: 22) { $0.curve = .arc(degrees: -150); $0.alignment = .center; $0.tracking = 80 }, x: 20, y: 110, box: 200))
        let wave = PathData(elements: [.move(Point(0, 40)), .cubic(Point(40, -10), Point(80, 90), Point(120, 40)), .cubic(Point(160, -10), Point(200, 90), Point(240, 40))])
        curved.append(textLayer("نص على مسار متموج — text on a wavy path", style("Cairo", size: 11, weight: 700) { $0.curve = .path(wave, offset: 6); $0.fill = RGBA(0.75, 0.15, 0.2) }, x: 0, y: 150))
        let curveDoc = Document(size: Size2(240, 240), dpi: 300, layers: curved)
        writePNG(compose(curveDoc, level: 2), name: "typography-curved.png")
    }
}
#endif
