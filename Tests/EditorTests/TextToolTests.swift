import XCTest
import CutLine
import DocumentModel
@testable import Editor

/// A stand-in for Core Text: each letter is half an em wide and every line is 1.2 em tall.
private final class MockShaper: TextShaping {
    var calls = 0
    func shape(text: String, style: TextStyle, boxWidth: Double?) -> ShapedText {
        calls += 1
        let lines = text.components(separatedBy: "\n")
        let width = Double(lines.map { $0.count }.max() ?? 0) * style.size * 0.5
        let height = Double(lines.count) * style.size * 1.2
        return ShapedText(outline: width > 0 ? .rect(Rect2(x: 0, y: 0, width: width, height: height)) : PathData(),
                          size: Size2(boxWidth ?? width, height))
    }
}

final class TextToolTests: XCTestCase {
    private var now: TimeInterval = 0

    private func make() -> (ToolController, DocumentStore, MockShaper) {
        let store = DocumentStore(document: Document(size: Size2(200, 200)), clock: { self.now })
        let tools = ToolController(store: store)
        tools.viewport = Viewport(zoom: 4, origin: Point(0, 0), viewSize: Size2(800, 800))
        let shaper = MockShaper()
        tools.textShaper = shaper
        return (tools, store, shaper)
    }

    private func click(_ t: ToolController, _ x: Double, _ y: Double) {
        let e = PointerEvent(canvas: Point(x, y), screen: Point(x * 4, y * 4))
        t.pointerDown(e); t.pointerUp(e)
    }

    func testClickWithTheTextToolPlacesLaidOutText() throws {
        let (t, s, _) = make()
        t.newTextStyle = TextStyle(family: "Amiri", size: 10)
        t.tool = .text
        click(t, 40, 60)
        XCTAssertEqual(s.document.layers.count, 1)
        guard case .text(let content) = s.document.layers[0].content else { return XCTFail("expected a text layer") }
        XCTAssertEqual(content.text, "Text")
        XCTAssertEqual(content.style.family, "Amiri")
        XCTAssertEqual(content.size.width, 20, accuracy: 1e-9)       // 4 letters x 5 mm
        XCTAssertNotNil(content.outline.bounds)
        XCTAssertEqual(s.document.worldBounds(of: s.document.layers[0].id)?.x ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(t.selection, [s.document.layers[0].id])
        XCTAssertEqual(t.tool, .select, "after placing text the arrow tool takes over")
        s.undo()
        XCTAssertTrue(s.document.layers.isEmpty)
    }

    func testTextToolDoesNothingWithoutAShaper() {
        let (t, s, _) = make()
        t.textShaper = nil
        t.tool = .text
        click(t, 40, 60)
        XCTAssertTrue(s.document.layers.isEmpty)
    }

    func testClickingExistingTextEditsItInsteadOfAddingMore() {
        let (t, s, _) = make()
        t.tool = .text
        click(t, 40, 60)
        t.tool = .text
        click(t, 42, 62)
        XCTAssertEqual(s.document.layers.count, 1)
        XCTAssertEqual(t.selection.count, 1)
    }

    func testEditingTextReshapesAndTypingIsOneUndoStep() throws {
        let (t, s, shaper) = make()
        t.newTextStyle = TextStyle(size: 10)
        t.tool = .text
        click(t, 10, 10)
        let id = s.document.layers[0].id
        for word in ["Te", "Tex", "Text!", "Text!!"] {
            now += 0.2
            t.updateText(id) { $0.text = word }
        }
        let sel = try XCTUnwrap(t.selectedText)
        XCTAssertEqual(sel.content.text, "Text!!")
        XCTAssertEqual(sel.content.size.width, 30, accuracy: 1e-9)
        XCTAssertGreaterThan(shaper.calls, 4)
        s.undo()
        XCTAssertEqual(t.selectedText?.content.text, "Text", "all the typing undoes together")
    }

    func testStyleChangeUsesTheNewStyle() {
        let (t, s, _) = make()
        t.tool = .text
        click(t, 10, 10)
        let id = s.document.layers[0].id
        t.updateText(id) { $0.style.size = 40; $0.style.fill = RGBA(1, 0, 0) }
        guard case .text(let c) = s.document.layer(id: id)!.content else { return XCTFail() }
        XCTAssertEqual(c.size.height, 48, accuracy: 1e-9)
        XCTAssertEqual(c.style.fill, RGBA(1, 0, 0))
    }

    func testTextLayersAreSelectableAndMovable() {
        let (t, s, _) = make()
        t.tool = .text
        click(t, 40, 60)
        let id = s.document.layers[0].id
        t.select([])
        // The mock text is 20 x 24 mm at (40, 60): clicking inside the box picks it.
        click(t, 50, 70)
        XCTAssertEqual(t.selection, [id])
        t.handleKey(.arrow(dx: 1, dy: 0), modifiers: .shift)
        XCTAssertEqual(s.document.worldBounds(of: id)?.x ?? 0, 41, accuracy: 1e-9)
    }

    func testResizingTextScalesItsOutlineNotItsStyle() {
        let (t, s, _) = make()
        t.tool = .text
        click(t, 40, 60)
        let id = s.document.layers[0].id
        let r = s.document.worldBounds(of: id)!
        let handle = t.handlePositions().first { $0.0 == .right }!.1
        let e0 = PointerEvent(canvas: handle), e1 = PointerEvent(canvas: Point(handle.x + r.width, handle.y))
        t.pointerDown(e0); t.pointerDragged(e1); t.pointerUp(e1)
        XCTAssertEqual(s.document.worldBounds(of: id)?.width ?? 0, r.width * 2, accuracy: 1e-6)
        guard case .text(let c) = s.document.layer(id: id)!.content else { return XCTFail() }
        XCTAssertEqual(c.style.size, TextStyle().size, "the font size setting is untouched; only the layer is scaled")
    }

    func testShortcutSwitchesTool() {
        let (t, _, _) = make()
        t.handleKey(.character("t"))
        XCTAssertEqual(t.tool, .text)
        t.handleKey(.character("v"))
        XCTAssertEqual(t.tool, .select)
    }

    func testReshapeAllReachesTextInsideGroups() {
        let shaper = MockShaper()
        let text = Layer(name: "t", content: .text(TextContent(text: "Hello", style: TextStyle(size: 10))))
        let group = Layer(name: "g", content: .group([text]))
        var doc = Document(size: Size2(100, 100), layers: [group])
        doc.reshapeAllText(using: shaper)
        guard case .text(let c) = doc.layer(id: text.id)!.content else { return XCTFail() }
        XCTAssertEqual(c.size.width, 25, accuracy: 1e-9)
        XCTAssertNotNil(c.outline.bounds)
    }

    func testTextContentSurvivesSaving() throws {
        let curve = TextCurve.path(PathData(elements: [.move(Point(0, 0)), .cubic(Point(10, 0), Point(20, 10), Point(30, 10))]), offset: 4)
        let style = TextStyle(family: "Amiri", weight: 700, italic: true, size: 24, tracking: 40, lineSpacing: 1.3,
                              alignment: .justified, direction: .rightToLeft, features: [FontFeature("liga"), FontFeature("ss01", 1)],
                              language: "ar", curve: curve, fill: RGBA(0.1, 0.2, 0.3), stroke: Stroke(color: .white, width: 0.5))
        let layer = Layer(name: "مرحبا", content: .text(TextContent(text: "مرحبا\nstar", style: style, boxWidth: 120,
                                                                      outline: .rect(Rect2(x: 0, y: 0, width: 5, height: 5)), size: Size2(120, 40))))
        let doc = Document(size: Size2(300, 400), layers: [layer])
        let back = try JSONDecoder().decode(Document.self, from: try JSONEncoder().encode(doc))
        XCTAssertEqual(back, doc)
    }
}
