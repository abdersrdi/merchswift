import XCTest
import CutLine
import DocumentModel
@testable import Editor

final class ToolControllerTests: XCTestCase {
    private var now: TimeInterval = 0

    private func rect(_ name: String, _ r: Rect2) -> Layer {
        Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: r.width, height: r.height)), fill: .black)),
              transform: .translation(r.x, r.y))
    }

    /// A 200 x 200 mm canvas viewed at 4 points per millimetre.
    private func make(_ layers: [Layer], snap: Bool = false) -> (ToolController, DocumentStore) {
        let store = DocumentStore(document: Document(size: Size2(200, 200), layers: layers), clock: { self.now })
        let tools = ToolController(store: store)
        tools.viewport = Viewport(zoom: 4, origin: Point(0, 0), viewSize: Size2(800, 800))
        if !snap { tools.snapSettings = SnapSettings(threshold: 1, toGuides: false, toCanvas: false, toObjects: false) }
        return (tools, store)
    }

    private func ev(_ x: Double, _ y: Double, _ m: Modifiers = [], clicks: Int = 1) -> PointerEvent {
        PointerEvent(canvas: Point(x, y), screen: Point(x * 4, y * 4), modifiers: m, kind: .mouse, clickCount: clicks)
    }

    private func drag(_ t: ToolController, from a: Point, to b: Point, _ m: Modifiers = [], steps: Int = 6) {
        t.pointerDown(ev(a.x, a.y, m))
        for i in 1...steps {
            let f = Double(i) / Double(steps)
            now += 0.016
            t.pointerDragged(ev(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, m))
        }
        t.pointerUp(ev(b.x, b.y, m))
    }

    private func bounds(_ s: DocumentStore, _ l: Layer) -> Rect2 { s.document.worldBounds(of: l.id)! }

    // MARK: Selecting

    func testClickSelectsTopmostAndClickOnEmptyClears() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 40, height: 40)), b = rect("b", Rect2(x: 30, y: 30, width: 40, height: 40))
        let (t, _) = make([a, b])
        t.pointerDown(ev(40, 40)); t.pointerUp(ev(40, 40))
        XCTAssertEqual(t.selection, [b.id])
        t.pointerDown(ev(15, 15)); t.pointerUp(ev(15, 15))
        XCTAssertEqual(t.selection, [a.id])
        t.pointerDown(ev(150, 150)); t.pointerUp(ev(150, 150))
        XCTAssertTrue(t.selection.isEmpty)
    }

    func testShiftClickAddsAndRemoves() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20)), b = rect("b", Rect2(x: 60, y: 10, width: 20, height: 20))
        let (t, _) = make([a, b])
        t.pointerDown(ev(15, 15)); t.pointerUp(ev(15, 15))
        t.pointerDown(ev(65, 15, .shift)); t.pointerUp(ev(65, 15, .shift))
        XCTAssertEqual(Set(t.selection), [a.id, b.id])
        t.pointerDown(ev(15, 15, .shift)); t.pointerUp(ev(15, 15, .shift))
        XCTAssertEqual(t.selection, [b.id])
    }

    func testClickingInsideAGroupSelectsTheGroup() {
        let inner = rect("inner", Rect2(x: 0, y: 0, width: 20, height: 20))
        let g = Layer(name: "g", content: .group([inner]), transform: .translation(50, 50))
        let (t, _) = make([g])
        t.pointerDown(ev(60, 60)); t.pointerUp(ev(60, 60))
        XCTAssertEqual(t.selection, [g.id])
    }

    func testMarqueeSelectsWhatItTouches() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20)), b = rect("b", Rect2(x: 100, y: 100, width: 20, height: 20))
        let c = rect("c", Rect2(x: 40, y: 10, width: 20, height: 20))
        let (t, _) = make([a, b, c])
        t.pointerDown(ev(5, 5))
        t.pointerDragged(ev(45, 45))
        XCTAssertNotNil(t.marquee)
        t.pointerUp(ev(45, 45))
        XCTAssertEqual(Set(t.selection), [a.id, c.id])
        XCTAssertNil(t.marquee)
    }

    func testClickingASelectedLayerInAMultiSelectionKeepsItUntilItIsAClick() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20)), b = rect("b", Rect2(x: 60, y: 10, width: 20, height: 20))
        let (t, _) = make([a, b])
        t.select([a.id, b.id])
        t.pointerDown(ev(15, 15)); t.pointerUp(ev(15, 15))
        XCTAssertEqual(t.selection, [a.id], "a plain click narrows the selection")

        t.select([a.id, b.id])
        drag(t, from: Point(15, 15), to: Point(25, 15))
        XCTAssertEqual(Set(t.selection), [a.id, b.id], "a drag moves both and keeps them selected")
    }

    // MARK: Moving

    func testDragMovesAndIsOneUndoStep() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20))
        let (t, s) = make([a])
        drag(t, from: Point(15, 15), to: Point(55, 35))
        let b = bounds(s, a)
        XCTAssertEqual(b.x, 50, accuracy: 1e-9); XCTAssertEqual(b.y, 30, accuracy: 1e-9)
        s.undo()
        XCTAssertEqual(bounds(s, a).x, 10, accuracy: 1e-9)
        XCTAssertFalse(s.canUndo, "selecting is not an undo step, the whole drag is one")
    }

    func testLongPauseInADragStaysOneStep() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20))
        let (t, s) = make([a])
        t.pointerDown(ev(15, 15))
        t.pointerDragged(ev(25, 15))
        now += 10
        t.pointerDragged(ev(35, 15))
        t.pointerUp(ev(35, 15))
        s.undo()
        XCTAssertEqual(bounds(s, a).x, 10, accuracy: 1e-9)
    }

    func testTinyMovementIsAClickNotADrag() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20))
        let (t, s) = make([a])
        t.pointerDown(ev(15, 15)); t.pointerDragged(ev(15.3, 15.2)); t.pointerUp(ev(15.3, 15.2))
        XCTAssertEqual(bounds(s, a).x, 10, accuracy: 1e-9)
        XCTAssertFalse(s.canUndo)
    }

    func testShiftConstrainsToAnAxis() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20))
        let (t, s) = make([a])
        drag(t, from: Point(15, 15), to: Point(65, 25), .shift)
        XCTAssertEqual(bounds(s, a).x, 60, accuracy: 1e-9)
        XCTAssertEqual(bounds(s, a).y, 10, accuracy: 1e-9)
    }

    func testMoveSnapsToCanvasEdgeAndShowsAGuide() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20))
        let (t, s) = make([a], snap: true)
        t.pointerDown(ev(15, 15))
        t.pointerDragged(ev(15 - 9.5, 15))          // left edge lands at 0.5 mm, within the 6 pt (1.5 mm) threshold
        XCTAssertEqual(bounds(s, a).x, 0, accuracy: 1e-9)
        XCTAssertTrue(t.snapLines.contains { $0.axis == .vertical && $0.position == 0 })
        XCTAssertTrue(t.overlayItems().contains { if case .polyline(_, _, let c, _, _) = $0 { return c == OverlayColors.guide } else { return false } })
        t.pointerUp(ev(5.5, 15))
        XCTAssertTrue(t.snapLines.isEmpty)
    }

    func testCommandDisablesSnapping() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20))
        let (t, s) = make([a], snap: true)
        drag(t, from: Point(15, 15), to: Point(15 - 9.5, 15), .command)
        XCTAssertEqual(bounds(s, a).x, 0.5, accuracy: 1e-9)
    }

    func testCancelPutsItBack() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20))
        let (t, s) = make([a])
        t.pointerDown(ev(15, 15)); t.pointerDragged(ev(45, 45))
        XCTAssertEqual(bounds(s, a).x, 40, accuracy: 1e-9)
        t.cancelInteraction()
        XCTAssertEqual(bounds(s, a).x, 10, accuracy: 1e-9)
        XCTAssertFalse(s.canUndo)
        XCTAssertFalse(s.canRedo)
    }

    func testLockedLayersCannotBeSelectedByClick() {
        var a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20))
        a.isLocked = true
        let (t, _) = make([a])
        t.pointerDown(ev(15, 15)); t.pointerUp(ev(15, 15))
        XCTAssertTrue(t.selection.isEmpty)
    }

    // MARK: Resizing and rotating

    private func handle(_ t: ToolController, _ h: SelectionHandle) -> Point { t.handlePositions().first { $0.0 == h }!.1 }

    func testResizeFromTheRightEdge() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 40, height: 20))
        let (t, s) = make([a])
        t.select([a.id])
        let h = handle(t, .right)
        drag(t, from: h, to: Point(h.x + 20, h.y))
        let b = bounds(s, a)
        XCTAssertEqual(b.x, 10, accuracy: 1e-9); XCTAssertEqual(b.width, 60, accuracy: 1e-9); XCTAssertEqual(b.height, 20, accuracy: 1e-9)
        s.undo()
        XCTAssertEqual(bounds(s, a).width, 40, accuracy: 1e-9)
    }

    func testCornerResizeWithShiftKeepsProportions() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 40, height: 20))
        let (t, s) = make([a])
        t.select([a.id])
        let h = handle(t, .bottomRight)
        drag(t, from: h, to: Point(h.x + 40, h.y + 2), .shift)     // mostly horizontal: width doubles
        let b = bounds(s, a)
        XCTAssertEqual(b.width / b.height, 2, accuracy: 1e-6)
        XCTAssertEqual(b.x, 10, accuracy: 1e-9); XCTAssertEqual(b.y, 10, accuracy: 1e-9)
    }

    func testOptionResizesAboutTheCentre() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 40, height: 20))
        let (t, s) = make([a])
        t.select([a.id])
        let h = handle(t, .right)
        drag(t, from: h, to: Point(h.x + 10, h.y), .option)
        let b = bounds(s, a)
        XCTAssertEqual(b.midX, 30, accuracy: 1e-9)
        XCTAssertEqual(b.width, 60, accuracy: 1e-9)
    }

    func testDraggingAHandlePastTheOppositeSideFlips() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 40, height: 20))
        let (t, s) = make([a])
        t.select([a.id])
        let h = handle(t, .right)
        drag(t, from: h, to: Point(-10, h.y))
        let b = bounds(s, a)
        XCTAssertEqual(b.minX, -10, accuracy: 1e-6)
        XCTAssertEqual(b.maxX, 10, accuracy: 1e-6)
    }

    func testRotateHandleTurnsTheLayer() {
        let a = rect("a", Rect2(x: 80, y: 90, width: 40, height: 20))   // centre (100, 100)
        let (t, s) = make([a])
        t.select([a.id])
        let r = handle(t, .rotate)                                      // straight above the centre
        drag(t, from: r, to: Point(100 + (100 - r.y), 100), .shift)     // a quarter turn clockwise on screen
        let b = bounds(s, a)
        XCTAssertEqual(b.width, 20, accuracy: 1e-6)
        XCTAssertEqual(b.height, 40, accuracy: 1e-6)
        XCTAssertEqual(b.midX, 100, accuracy: 1e-6); XCTAssertEqual(b.midY, 100, accuracy: 1e-6)
    }

    func testHandlesKeepTheirScreenSizeAtAnyZoom() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 40, height: 20))
        let (t, _) = make([a])
        t.select([a.id])
        let near = t.handlePositions().first { $0.0 == .rotate }!.1
        t.viewport.zoom = 1
        let far = t.handlePositions().first { $0.0 == .rotate }!.1
        XCTAssertEqual(10 - near.y, 26 / 4, accuracy: 1e-9)
        XCTAssertEqual(10 - far.y, 26, accuracy: 1e-9)
    }

    // MARK: Keys and actions

    func testDeleteArrowsAndShortcuts() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20)), b = rect("b", Rect2(x: 60, y: 10, width: 20, height: 20))
        let (t, s) = make([a, b])
        t.select([a.id])
        XCTAssertTrue(t.handleKey(.arrow(dx: 1, dy: 0)))
        XCTAssertEqual(bounds(s, a).x, 10.1, accuracy: 1e-9)
        XCTAssertTrue(t.handleKey(.arrow(dx: 0, dy: 1), modifiers: .shift))
        XCTAssertEqual(bounds(s, a).y, 11, accuracy: 1e-9)

        t.handleKey(.character("d"), modifiers: .command)
        XCTAssertEqual(s.document.layers.count, 3)
        XCTAssertEqual(t.selection.count, 1)
        XCTAssertNotEqual(t.selection.first, a.id)

        XCTAssertTrue(t.handleKey(.delete))
        XCTAssertEqual(s.document.layers.count, 2)
        XCTAssertTrue(t.selection.isEmpty)
        t.handleKey(.character("z"), modifiers: .command)
        XCTAssertEqual(s.document.layers.count, 3)
        XCTAssertEqual(t.selection, [], "the selection follows what exists after an undo")

        t.handleKey(.character("a"), modifiers: .command)
        XCTAssertEqual(t.selection.count, 3)
        t.handleKey(.character("g"), modifiers: .command)
        XCTAssertEqual(s.document.layers.count, 1)
        t.handleKey(.character("g"), modifiers: [.command, .shift])
        XCTAssertEqual(s.document.layers.count, 3)
        XCTAssertTrue(t.handleKey(.escape))
        XCTAssertTrue(t.selection.isEmpty)
    }

    func testNudgeIsOneUndoStepPerBurst() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 20, height: 20))
        let (t, s) = make([a])
        t.select([a.id])
        for _ in 0..<5 { now += 0.1; t.handleKey(.arrow(dx: 1, dy: 0), modifiers: .shift) }
        XCTAssertEqual(bounds(s, a).x, 15, accuracy: 1e-9)
        s.undo()
        XCTAssertEqual(bounds(s, a).x, 10, accuracy: 1e-9)
    }

    func testCombineAndInspectorEdits() {
        let a = rect("a", Rect2(x: 0, y: 0, width: 10, height: 10)), b = rect("b", Rect2(x: 5, y: 0, width: 10, height: 10))
        let (t, s) = make([a, b])
        t.select([a.id, b.id])
        XCTAssertTrue(t.canCombine)
        t.combineSelection(.union)
        XCTAssertEqual(s.document.layers.count, 1)
        XCTAssertEqual(t.selection.count, 1)

        t.setFrame(Rect2(x: 20, y: 30, width: 60, height: 40))
        let b2 = s.document.worldBounds(of: t.selection[0])!
        XCTAssertEqual(b2.x, 20, accuracy: 1e-9); XCTAssertEqual(b2.height, 40, accuracy: 1e-9)

        t.setOpacity(0.4)
        XCTAssertEqual(s.document.layer(id: t.selection[0])?.opacity ?? 0, 0.4, accuracy: 1e-9)
        t.setBlendMode(.multiply)
        XCTAssertEqual(s.document.layer(id: t.selection[0])?.blendMode, .multiply)
    }

    func testCannotCombineAnImage() {
        let a = rect("a", Rect2(x: 0, y: 0, width: 10, height: 10))
        let img = Layer(name: "i", content: .image(ImageContent(assetID: "x", size: Size2(5, 5))))
        let (t, _) = make([a, img])
        t.select([a.id, img.id])
        XCTAssertFalse(t.canCombine)
    }

    // MARK: Overlay

    func testSelectionOverlayHasNineHandles() {
        let a = rect("a", Rect2(x: 10, y: 10, width: 40, height: 20))
        let (t, _) = make([a])
        t.select([a.id])
        let markers = t.overlayItems().filter { if case .marker = $0 { return true } else { return false } }
        XCTAssertEqual(markers.count, 9)
        t.select([])
        XCTAssertTrue(t.overlayItems().isEmpty)
    }

    // MARK: Pen

    func testPenClicksCloseIntoAShape() {
        let (t, s) = make([])
        t.tool = .pen
        for p in [Point(20, 20), Point(80, 20), Point(80, 80)] { t.pointerDown(ev(p.x, p.y)); t.pointerUp(ev(p.x, p.y)) }
        XCTAssertTrue(s.document.layers.isEmpty, "nothing is added until the path is finished")
        XCTAssertFalse(t.overlayItems().isEmpty, "the path in progress is drawn")
        t.pointerDown(ev(20.5, 20.5)); t.pointerUp(ev(20.5, 20.5))     // back on the first point
        XCTAssertEqual(s.document.layers.count, 1)
        guard case .shape(let shape) = s.document.layers[0].content else { return XCTFail() }
        XCTAssertNotNil(shape.fill)
        XCTAssertEqual(shape.path.closedSubpathCount, 1)
        XCTAssertEqual(t.selection, [s.document.layers[0].id])
        s.undo()
        XCTAssertTrue(s.document.layers.isEmpty)
    }

    func testPenDragMakesACurve() {
        let (t, s) = make([])
        t.tool = .pen
        t.pointerDown(ev(20, 50)); t.pointerUp(ev(20, 50))
        t.pointerDown(ev(80, 50)); t.pointerDragged(ev(95, 30)); t.pointerUp(ev(95, 30))
        t.finishPath()
        guard case .shape(let shape) = s.document.layers[0].content else { return XCTFail() }
        XCTAssertTrue(shape.path.elements.contains { if case .cubic = $0 { return true } else { return false } })
        XCTAssertNil(shape.fill, "an open path is a stroke")
        XCTAssertNotNil(shape.stroke)
    }

    func testPenDoubleClickFinishesAnOpenPath() {
        let (t, s) = make([])
        t.tool = .pen
        for p in [Point(20, 20), Point(80, 20), Point(80, 80)] { t.pointerDown(ev(p.x, p.y)); t.pointerUp(ev(p.x, p.y)) }
        t.pointerDown(ev(80, 80, clicks: 2)); t.pointerUp(ev(80, 80, clicks: 2))
        XCTAssertEqual(s.document.layers.count, 1)
    }

    func testPenEscapeCancelsAndDeleteRemovesTheLastPoint() {
        let (t, s) = make([])
        t.tool = .pen
        for p in [Point(20, 20), Point(80, 20), Point(80, 80)] { t.pointerDown(ev(p.x, p.y)); t.pointerUp(ev(p.x, p.y)) }
        XCTAssertTrue(t.handleKey(.delete))
        t.finishPath()
        XCTAssertEqual(s.document.layers.count, 1, "two points still make a path")
        let (t2, s2) = make([])
        t2.tool = .pen
        t2.pointerDown(ev(20, 20)); t2.pointerUp(ev(20, 20))
        t2.pointerDown(ev(60, 20)); t2.pointerUp(ev(60, 20))
        XCTAssertTrue(t2.handleKey(.escape))
        XCTAssertTrue(s2.document.layers.isEmpty)
    }

    func testEditingAnAnchorOfAnExistingPath() {
        var pen = PenPath()
        for p in [Point(20, 20), Point(80, 20), Point(80, 80), Point(20, 80)] { pen.addAnchor(at: p) }
        pen.close()
        var doc = Document(size: Size2(200, 200))
        let id = doc.addShape(from: pen)
        let store = DocumentStore(document: doc, clock: { self.now })
        let t = ToolController(store: store)
        t.viewport = Viewport(zoom: 4, origin: Point(0, 0), viewSize: Size2(800, 800))
        t.select([id])
        t.tool = .pen

        drag(t, from: Point(80, 80), to: Point(100, 90))
        let moved = PenPath(pathData: { if case .shape(let s) = store.document.layer(id: id)!.content { return s.path } else { return PathData() } }())
        XCTAssertEqual(moved.anchors[2].position.x, 100, accuracy: 1e-9)
        XCTAssertEqual(moved.anchors[2].position.y, 90, accuracy: 1e-9)
        XCTAssertEqual(moved.anchors.count, 4)
        store.undo()
        XCTAssertEqual(store.document.worldBounds(of: id)?.maxX ?? 0, 80, accuracy: 1e-9, "the drag undoes in one step")
    }

    func testClickOnASegmentInsertsAnAnchorAndDoubleClickTogglesSmooth() {
        var pen = PenPath()
        for p in [Point(20, 20), Point(80, 20), Point(80, 80), Point(20, 80)] { pen.addAnchor(at: p) }
        pen.close()
        var doc = Document(size: Size2(200, 200))
        let id = doc.addShape(from: pen)
        let store = DocumentStore(document: doc, clock: { self.now })
        let t = ToolController(store: store)
        t.viewport = Viewport(zoom: 4, origin: Point(0, 0), viewSize: Size2(800, 800))
        t.select([id])
        t.tool = .pen

        t.pointerDown(ev(50, 20)); t.pointerUp(ev(50, 20))          // on the top side
        func current() -> PenPath { if case .shape(let s) = store.document.layer(id: id)!.content { return PenPath(pathData: s.path) } else { return PenPath() } }
        XCTAssertEqual(current().anchors.count, 5)

        t.pointerDown(ev(80, 80, clicks: 2)); t.pointerUp(ev(80, 80, clicks: 2))
        let p = current()
        let corner = p.anchors.first { abs($0.position.x - 80) < 1e-6 && abs($0.position.y - 80) < 1e-6 }
        XCTAssertNotNil(corner?.handleOut, "double click converts a corner to a smooth point")
    }

    func testSwitchingToolsAbandonsAPathInProgress() {
        let (t, s) = make([])
        t.tool = .pen
        t.pointerDown(ev(20, 20)); t.pointerUp(ev(20, 20))
        t.tool = .select
        t.tool = .pen
        t.pointerDown(ev(30, 30)); t.pointerUp(ev(30, 30))
        t.finishPath()
        XCTAssertTrue(s.document.layers.isEmpty, "a single point is not a path")
    }
}
