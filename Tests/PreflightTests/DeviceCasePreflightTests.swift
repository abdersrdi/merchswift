import XCTest
import CutLine
import DocumentModel
import Products
@testable import Preflight

private final class Shaper: TextShaping {
    func shape(text: String, style: TextStyle, boxWidth: Double?) -> ShapedText {
        ShapedText(outline: .rect(Rect2(x: 0, y: 0, width: Double(text.count) * style.size * 0.5, height: style.size)),
                   size: Size2(Double(text.count) * style.size * 0.5, style.size))
    }
}

final class DeviceCasePreflightTests: XCTestCase {
    private var plateauCase: ProductPreset { DeviceCaseCatalog.all.first { $0.name.contains("plateau") && $0.trim == Size2(78, 163.4) }! }
    private var squareCase: ProductPreset { DeviceCaseCatalog.all.first { $0.name.contains("square") && $0.trim == Size2(77.6, 163) }! }

    private func background(_ p: ProductPreset, _ c: RGBA = RGBA(0.2, 0.4, 0.8)) -> Layer {
        Layer(name: "bg", content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: p.canvas.width, height: p.canvas.height)), fill: c)))
    }

    private func text(_ s: String, size: Double, at p: Point) -> Layer {
        var c = TextContent(text: s, style: TextStyle(size: size))
        c.reshape(using: Shaper())
        return Layer(name: s, content: .text(c), transform: .translation(p.x, p.y))
    }

    private func zoneIssues(_ d: Document) -> [PreflightIssue] { Preflight.run(d).issues.filter { $0.check == .mugHandle } }

    func testTextOverTheCameraPlateauIsFlaggedAndCanMoveBelowIt() throws {
        let p = plateauCase
        var d = p.makeDocument()
        d.layers = [background(p), text("Hello", size: 12, at: Point(20, 20))]
        let found = try XCTUnwrap(zoneIssues(d).first)
        XCTAssertTrue(found.title.contains("camera"), found.title)
        XCTAssertFalse(found.detail.contains("handle"))
        guard case .move(_, let dx, let dy)? = found.fix else { return XCTFail("expected a move below the camera") }
        XCTAssertEqual(dx, 0); XCTAssertGreaterThan(dy, 20)
        var fixed = d
        XCTAssertTrue(Preflight.apply(found.fix!, to: &fixed))
        XCTAssertTrue(zoneIssues(fixed).isEmpty)
    }

    func testBackgroundsMayRunBehindTheCamera() {
        let p = squareCase
        var d = p.makeDocument()
        d.layers = [background(p, RGBA(0.9, 0.5, 0.1))]
        XCTAssertTrue(zoneIssues(d).isEmpty)
        XCTAssertTrue(Preflight.run(d).issues.filter { $0.check == .bleed }.isEmpty, "a full-bleed background satisfies the bleed check")
    }

    func testArtOutsideTheCameraIsFine() {
        let p = squareCase
        var d = p.makeDocument()
        d.layers = [background(p, RGBA(0.2, 0.2, 0.2)), text("Low", size: 12, at: Point(20, 100))]
        XCTAssertTrue(zoneIssues(d).isEmpty)
    }

    func testCaseWithoutABackgroundGetsABleedError() {
        let p = squareCase
        var d = p.makeDocument()
        d.layers = [text("Low", size: 12, at: Point(20, 100))]
        XCTAssertEqual(Preflight.run(d).issues.first { $0.check == .bleed }?.severity, .error)
    }

    func testMugStillTalksAboutTheHandle() throws {
        let m = ProductCatalog.mug11
        var d = m.makeDocument()
        d.layers = [Layer(name: "bg", content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: m.canvas.width, height: m.canvas.height)), fill: .black))),
                    text("Hi", size: 20, at: Point(5, 30))]
        let found = try XCTUnwrap(zoneIssues(d).first)
        XCTAssertTrue(found.title.contains("handle"))
    }
}
