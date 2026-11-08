import XCTest
import CutLine
import DocumentModel
import Products
@testable import Preflight

private struct FakeGamut: GamutChecking {
    func isInGamut(_ c: RGBA) -> Bool { max(c.r, c.g, c.b) <= 0.9 }
    func nearestInGamut(_ c: RGBA) -> RGBA { RGBA(min(c.r, 0.9), min(c.g, 0.9), min(c.b, 0.9), c.a) }
}

private final class FixedShaper: TextShaping {
    func shape(text: String, style: TextStyle, boxWidth: Double?) -> ShapedText {
        ShapedText(outline: .rect(Rect2(x: 0, y: 0, width: Double(text.count) * style.size * 0.5, height: style.size)),
                   size: Size2(Double(text.count) * style.size * 0.5, style.size))
    }
}

final class PreflightTests: XCTestCase {
    private let tee = ProductCatalog.tshirtFront                  // 300 x 400, no bleed, safe 5, transparent
    private let sticker = ProductCatalog.dieCutSticker           // canvas 81 x 81, trim at 3, safe at 6
    private let mug = ProductCatalog.mug11

    private func shape(_ name: String, _ r: Rect2, fill: RGBA? = .black, stroke: Stroke? = nil, opacity: Double = 1) -> Layer {
        Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: r.width, height: r.height)), fill: fill, stroke: stroke)),
              transform: .translation(r.x, r.y), opacity: opacity)
    }

    private func text(_ s: String, size: Double, at p: Point, stroke: Stroke? = nil) -> Layer {
        var c = TextContent(text: s, style: TextStyle(size: size, stroke: stroke))
        c.reshape(using: FixedShaper())
        return Layer(name: s, content: .text(c), transform: .translation(p.x, p.y))
    }

    private func image(_ name: String, mm: Size2, px: (Int, Int)?, at p: Point = Point(20, 20)) -> Layer {
        Layer(name: name, content: .image(ImageContent(assetID: name, size: mm, pixelWidth: px?.0, pixelHeight: px?.1)),
              transform: .translation(p.x, p.y))
    }

    private func doc(_ preset: ProductPreset, _ layers: [Layer]) -> Document {
        var d = preset.makeDocument()
        d.layers = layers
        return d
    }

    private func run(_ d: Document, cut: CutPath? = nil, gamut: GamutChecking? = nil) -> PreflightReport {
        Preflight.run(d, cutPath: cut, gamut: gamut)
    }

    private func issues(_ r: PreflightReport, _ c: PreflightCheck) -> [PreflightIssue] { r.issues.filter { $0.check == c } }

    // MARK: Clean

    func testAGoodDesignHasNoIssues() {
        let d = doc(tee, [shape("badge", Rect2(x: 50, y: 60, width: 200, height: 200)), text("Hello", size: 20, at: Point(60, 300))])
        XCTAssertTrue(run(d).isClean, "\(run(d).issues.map { $0.title })")
        XCTAssertTrue(run(d).canExport)
    }

    // MARK: Resolution

    func testLowResolutionImage() throws {
        // 600 px across 150 mm is 101.6 DPI.
        let d = doc(tee, [image("photo", mm: Size2(150, 100), px: (600, 400))])
        let r = run(d)
        let found = try XCTUnwrap(issues(r, .resolution).first)
        XCTAssertEqual(found.severity, .error, "under half the needed DPI is an error")
        XCTAssertTrue(found.detail.contains("102 DPI"), found.detail)
        XCTAssertEqual(found.fix, .upscaleImage(layer: d.layers[0].id, targetDPI: 300))
        XCTAssertFalse(r.canExport)
    }

    func testBorderlineResolutionIsAWarningAndGoodResolutionPasses() {
        // 1500 px over 150 mm = 254 DPI: warning. 1800 px = 304.8 DPI: fine.
        XCTAssertEqual(issues(run(doc(tee, [image("a", mm: Size2(150, 100), px: (1500, 1000))])), .resolution).first?.severity, .warning)
        XCTAssertTrue(issues(run(doc(tee, [image("b", mm: Size2(150, 100), px: (1800, 1200))])), .resolution).isEmpty)
        XCTAssertTrue(issues(run(doc(tee, [image("c", mm: Size2(150, 100), px: nil)])), .resolution).isEmpty, "unknown pixel size is not guessed")
    }

    func testScalingAnImageChangesItsResolution() {
        var l = image("p", mm: Size2(50, 50), px: (600, 600))          // 304.8 DPI at 50 mm
        XCTAssertTrue(issues(run(doc(tee, [l])), .resolution).isEmpty)
        l.transform = Transform2D.scale(3, 3).then(.translation(20, 20))   // now 150 mm: 101.6 DPI
        XCTAssertEqual(issues(run(doc(tee, [l])), .resolution).count, 1)
    }

    func testResolutionTargetFollowsTheDocumentDPI() {
        var d = doc(tee.with(dpi: 600), [image("p", mm: Size2(50, 50), px: (600, 600))])
        d.dpi = 600
        XCTAssertEqual(issues(run(d), .resolution).count, 1, "at 600 DPI the same picture is too small")
    }

    // MARK: Safe area

    func testTextOutsideTheSafeAreaCanBeMovedIn() throws {
        let d = doc(tee, [text("Hi", size: 20, at: Point(1, 1))])      // 5 mm safe inset
        let found = try XCTUnwrap(issues(run(d), .safeArea).first)
        guard case .move(_, let dx, let dy)? = found.fix else { return XCTFail("expected a move") }
        XCTAssertEqual(dx, 4, accuracy: 1e-9); XCTAssertEqual(dy, 4, accuracy: 1e-9)
        var fixed = d
        XCTAssertTrue(Preflight.apply(found.fix!, to: &fixed))
        XCTAssertTrue(issues(run(fixed), .safeArea).isEmpty)
    }

    func testBackgroundsAreNotSafeAreaProblems() {
        let d = doc(sticker, [shape("art", Rect2(x: 0, y: 0, width: 81, height: 81)), text("Hi", size: 8, at: Point(30, 30))])
        XCTAssertTrue(issues(run(d), .safeArea).isEmpty)
    }

    func testTooBigForTheSafeAreaHasNoMoveFix() throws {
        let d = doc(sticker, [text("A long caption that cannot fit", size: 10, at: Point(0, 20))])
        let found = try XCTUnwrap(issues(run(d), .safeArea).first)
        XCTAssertNil(found.fix)
    }

    // MARK: Bleed

    func testMugArtMustReachTheBleedEdge() throws {
        let c = mug.canvas
        let short = shape("bg", Rect2(x: 3, y: 3, width: c.width - 6, height: c.height - 6), fill: RGBA(0.2, 0.4, 0.8))
        let d = doc(mug, [short])
        let found = try XCTUnwrap(issues(run(d), .bleed).first)
        XCTAssertEqual(found.severity, .error)
        XCTAssertEqual(found.fix, .extendToBleed(layer: short.id))
        var fixed = d
        XCTAssertTrue(Preflight.apply(found.fix!, to: &fixed))
        XCTAssertTrue(issues(run(fixed), .bleed).isEmpty)
        let b = fixed.worldBounds(of: short.id)!
        XCTAssertEqual(b.minX, 0, accuracy: 1e-9); XCTAssertEqual(b.maxY, c.height, accuracy: 1e-9)
    }

    func testNoBleedCheckForProductsThatDoNotNeedIt() {
        XCTAssertTrue(issues(run(doc(tee, [shape("x", Rect2(x: 50, y: 50, width: 100, height: 100))])), .bleed).isEmpty)
        let full = shape("bg", Rect2(x: 0, y: 0, width: mug.canvas.width, height: mug.canvas.height))
        XCTAssertTrue(issues(run(doc(mug, [full])), .bleed).isEmpty)
    }

    func testSmallArtOnAMugHasNoQuickFix() throws {
        let d = doc(mug, [shape("dot", Rect2(x: 100, y: 30, width: 20, height: 20))])
        let found = try XCTUnwrap(issues(run(d), .bleed).first)
        XCTAssertNil(found.fix)
    }

    // MARK: Lines and text

    func testThinLines() throws {
        let d = doc(tee, [shape("frame", Rect2(x: 50, y: 50, width: 100, height: 100), fill: nil, stroke: Stroke(color: .black, width: 0.1))])
        let found = try XCTUnwrap(issues(run(d), .thinLine).first)
        XCTAssertEqual(found.fix, .thickenStroke(layer: d.layers[0].id, to: 0.25))
        var fixed = d
        Preflight.apply(found.fix!, to: &fixed)
        XCTAssertTrue(issues(run(fixed), .thinLine).isEmpty)
        XCTAssertTrue(issues(run(doc(tee, [shape("ok", Rect2(x: 50, y: 50, width: 100, height: 100), fill: nil, stroke: Stroke(color: .black, width: 0.3))])), .thinLine).isEmpty)
    }

    func testThinLineIsJudgedAfterScaling() {
        var l = shape("frame", Rect2(x: 0, y: 0, width: 10, height: 10), fill: nil, stroke: Stroke(color: .black, width: 0.1))
        l.transform = Transform2D.scale(4, 4).then(.translation(50, 50))          // 0.4 mm on the product
        XCTAssertTrue(issues(run(doc(tee, [l])), .thinLine).isEmpty)
        l.transform = Transform2D.scale(0.5, 0.5).then(.translation(50, 50))      // 0.05 mm
        XCTAssertEqual(issues(run(doc(tee, [l])), .thinLine).count, 1)
    }

    func testSmallText() throws {
        // 6 pt is 2.117 mm.
        let small = doc(tee, [text("tiny print", size: 1.5, at: Point(100, 100))])
        let found = try XCTUnwrap(issues(run(small), .smallText).first)
        guard case .enlargeText(_, let size)? = found.fix else { return XCTFail() }
        XCTAssertEqual(size, 6 * 25.4 / 72, accuracy: 1e-6)
        var fixed = small
        Preflight.apply(found.fix!, to: &fixed, shaper: FixedShaper())
        XCTAssertTrue(issues(run(fixed), .smallText).isEmpty)
        XCTAssertTrue(issues(run(doc(tee, [text("fine", size: 3, at: Point(100, 100))])), .smallText).isEmpty)
        XCTAssertTrue(issues(run(doc(tee, [text("  ", size: 0.5, at: Point(100, 100))])), .smallText).isEmpty, "blank text is not judged")
    }

    func testTextThatCouldNotBeLaidOutIsAnError() {
        let broken = Layer(name: "t", content: .text(TextContent(text: "Hello", style: TextStyle())), transform: .translation(60, 60))
        let r = run(doc(tee, [broken]))
        XCTAssertEqual(issues(r, .fonts).first?.severity, .error)
        XCTAssertFalse(r.canExport)
    }

    // MARK: Transparency

    func testSemiTransparencyOnTransparentProducts() throws {
        let faded = shape("glow", Rect2(x: 50, y: 50, width: 100, height: 100), opacity: 0.5)
        let d = doc(tee, [faded])
        let found = try XCTUnwrap(issues(run(d), .semiTransparency).first)
        XCTAssertTrue(found.detail.contains("50%"))
        var fixed = d
        Preflight.apply(found.fix!, to: &fixed)
        XCTAssertTrue(issues(run(fixed), .semiTransparency).isEmpty)
        XCTAssertEqual(fixed.layers[0].opacity, 1)
    }

    func testEachKindOfTransparencyIsFound() {
        var blend = shape("b", Rect2(x: 10, y: 10, width: 20, height: 20)); blend.blendMode = .multiply
        let softFill = shape("f", Rect2(x: 40, y: 10, width: 20, height: 20), fill: RGBA(0, 0, 0, 0.4))
        let softText = Layer(name: "t", content: .text(TextContent(text: "x", style: TextStyle(fill: RGBA(0, 0, 0, 0.5)), outline: .rect(Rect2(x: 0, y: 0, width: 5, height: 5)))),
                             transform: .translation(70, 10))
        let group = Layer(name: "g", content: .group([shape("inner", Rect2(x: 0, y: 0, width: 10, height: 10))]), transform: .translation(100, 10), opacity: 0.7)
        let r = run(doc(tee, [blend, softFill, softText, group]))
        XCTAssertEqual(issues(r, .semiTransparency).count, 4)
    }

    func testTransparencyIsFineOnProductsPrintedOnWhite() {
        let faded = shape("shadow", Rect2(x: 3, y: 3, width: mug.canvas.width - 6, height: 40), opacity: 0.5)
        let bg = shape("bg", Rect2(x: 0, y: 0, width: mug.canvas.width, height: mug.canvas.height))
        XCTAssertTrue(issues(run(doc(mug, [bg, faded])), .semiTransparency).isEmpty)
    }

    // MARK: Colour

    func testOutOfGamutColoursOnlyWhenAskedAndFixable() throws {
        let vivid = shape("neon", Rect2(x: 50, y: 50, width: 100, height: 100), fill: RGBA(0, 1, 0.2))
        let d = doc(tee, [vivid])
        XCTAssertTrue(issues(run(d), .gamut).isEmpty, "no profile, no check")
        let found = try XCTUnwrap(issues(run(d, gamut: FakeGamut()), .gamut).first)
        XCTAssertEqual(found.fix, .replaceColor(layer: vivid.id, target: .fill, with: RGBA(0, 0.9, 0.2)))
        var fixed = d
        Preflight.apply(found.fix!, to: &fixed)
        XCTAssertTrue(issues(run(fixed, gamut: FakeGamut()), .gamut).isEmpty)
    }

    func testFillAndStrokeAreReportedSeparately() {
        let l = shape("both", Rect2(x: 50, y: 50, width: 100, height: 100), fill: RGBA(1, 0, 0), stroke: Stroke(color: RGBA(0, 1, 0), width: 1))
        XCTAssertEqual(issues(run(doc(tee, [l]), gamut: FakeGamut()), .gamut).count, 2)
    }

    // MARK: Cut line

    func testCutLineTooCloseAndTooComplex() throws {
        var d = doc(sticker, [shape("art", Rect2(x: 10, y: 10, width: 60, height: 60))])
        d.cutLine = CutLineSettings(offset: 0.4, smoothing: 1)
        let close = try XCTUnwrap(issues(run(d), .cutLine).first)
        XCTAssertEqual(close.fix, .setCutOffset(1.5))
        Preflight.apply(close.fix!, to: &d)
        XCTAssertEqual(d.cutLine?.offset, 1.5)
        XCTAssertTrue(issues(run(d), .cutLine).isEmpty)

        let seg = CubicBezier(Point(0, 0), Point(1, 0), Point(2, 1), Point(3, 1))
        let heavy = CutPath(contours: [Contour(segments: Array(repeating: seg, count: 1600))])
        let r = run(d, cut: heavy)
        XCTAssertTrue(issues(r, .cutLine).contains { $0.fix == .simplifyCutLine && $0.severity == .warning })
    }

    func testSelfCrossingCutLineIsAnError() {
        func line(_ a: Point, _ b: Point) -> CubicBezier { CubicBezier(a, a + (b - a) * (1.0 / 3), a + (b - a) * (2.0 / 3), b) }
        // A bow tie: the two diagonals cross in the middle.
        let bow = Contour(segments: [line(Point(0, 0), Point(10, 10)), line(Point(10, 10), Point(10, 0)),
                                     line(Point(10, 0), Point(0, 10)), line(Point(0, 10), Point(0, 0))])
        let d = doc(sticker, [shape("art", Rect2(x: 10, y: 10, width: 60, height: 60))])
        let report = run(d, cut: CutPath(contours: [bow]))
        let crossing = issues(report, .cutLine).first { $0.severity == .error }
        XCTAssertNotNil(crossing)
        XCTAssertFalse(report.canExport)
        XCTAssertEqual(crossing?.fix, .simplifyCutLine)
    }

    func testNoCutLineChecksForProductsWithoutOne() {
        XCTAssertTrue(issues(run(doc(tee, [shape("x", Rect2(x: 50, y: 50, width: 100, height: 100))])), .cutLine).isEmpty)
    }

    // MARK: Mug handle

    func testHandleZone() throws {
        let inZone = text("Hi", size: 20, at: Point(5, 30))         // handle band is x 3...21
        let d = doc(mug, [shape("bg", Rect2(x: 0, y: 0, width: mug.canvas.width, height: mug.canvas.height)), inZone])
        let found = try XCTUnwrap(issues(run(d), .mugHandle).first)
        guard case .move(_, let dx, _)? = found.fix else { return XCTFail("expected a move") }
        XCTAssertGreaterThan(dx, 0)
        var fixed = d
        Preflight.apply(found.fix!, to: &fixed)
        XCTAssertTrue(issues(run(fixed), .mugHandle).isEmpty)
    }

    func testCentredArtIsClearOfTheHandle() {
        let d = doc(mug, [shape("bg", Rect2(x: 0, y: 0, width: mug.canvas.width, height: mug.canvas.height)), text("Hello", size: 20, at: Point(100, 40))])
        XCTAssertTrue(issues(run(d), .mugHandle).isEmpty)
    }

    // MARK: Ordering, hidden layers, fixing everything

    func testErrorsComeFirstAndHiddenLayersAreIgnored() {
        var hidden = shape("hidden", Rect2(x: 50, y: 50, width: 100, height: 100), opacity: 0.3)
        hidden.isVisible = false
        let d = doc(tee, [hidden, text("tiny", size: 1, at: Point(100, 100)), image("p", mm: Size2(150, 100), px: (300, 200))])
        let r = run(d)
        XCTAssertEqual(r.issues.first?.severity, .error)
        XCTAssertTrue(issues(r, .semiTransparency).isEmpty)
        XCTAssertEqual(r.issues.map { $0.severity }, r.issues.map { $0.severity }.sorted())
    }

    func testFixAllClearsWhatCanBeFixed() {
        let d0 = doc(tee, [
            shape("frame", Rect2(x: 50, y: 50, width: 100, height: 100), fill: .black, stroke: Stroke(color: .black, width: 0.05), opacity: 0.6),
            text("tiny", size: 1, at: Point(100, 100)),
            text("edge", size: 20, at: Point(0, 0)),
        ])
        var d = d0
        let before = run(d)
        XCTAssertGreaterThanOrEqual(before.issues.count, 4)
        let after = Preflight.fixAll(&d, shaper: FixedShaper())
        XCTAssertTrue(after.isClean, "\(after.issues.map { $0.title })")
    }

    func testFixesThatNeedAMissingToolReportFailure() {
        var d = doc(tee, [image("p", mm: Size2(150, 100), px: (300, 200))])
        XCTAssertFalse(Preflight.apply(.upscaleImage(layer: d.layers[0].id, targetDPI: 300), to: &d))
        XCTAssertFalse(Preflight.apply(.move(layer: UUID(), dx: 1, dy: 1), to: &d), "a missing layer is not an error to crash on")
    }

    func testPlainLanguage() {
        let d = doc(tee, [image("photo", mm: Size2(150, 100), px: (600, 400)), text("tiny", size: 1, at: Point(100, 100))])
        for issue in run(d).issues {
            XCTAssertFalse(issue.title.isEmpty)
            XCTAssertGreaterThan(issue.detail.count, 30, "each issue explains itself")
        }
    }
}
