import XCTest
import CutLine
import DocumentModel
@testable import Editor

final class EditorTests: XCTestCase {
    private func shape(_ name: String, _ r: Rect2) -> Layer {
        Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: r.width, height: r.height)), fill: .black)),
              transform: .translation(r.x, r.y))
    }

    // MARK: Snapping

    func testSnapsToCanvasCentreAndEdges() {
        let doc = Document(size: Size2(200, 300))
        let moving = Rect2(x: 89.4, y: 0.5, width: 20, height: 20)   // centre x = 99.4, top = 0.5
        let r = Snapper.snap(moving: moving, others: [], document: doc, settings: SnapSettings(threshold: 1))
        XCTAssertEqual(r.delta.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(r.delta.y, -0.5, accuracy: 1e-9)
        XCTAssertEqual(Set(r.lines.map { $0.position }), [100, 0])
    }

    func testSnapsToGuideAndOtherObjects() {
        let doc = Document(size: Size2(200, 300), guides: [Guide(axis: .vertical, position: 50)])
        let other = Rect2(x: 120, y: 100, width: 30, height: 30)
        let moving = Rect2(x: 20.3, y: 99.2, width: 30, height: 10)  // right edge 50.3 -> guide; top 99.2 -> other.minY 100
        let r = Snapper.snap(moving: moving, others: [other], document: doc, settings: SnapSettings(threshold: 1, toCanvas: false))
        XCTAssertEqual(r.delta.x, -0.3, accuracy: 1e-9)
        XCTAssertEqual(r.delta.y, 0.8, accuracy: 1e-9)
        XCTAssertEqual(r.lines.first(where: { $0.axis == .vertical })?.kind, .guide)
        XCTAssertEqual(r.lines.first(where: { $0.axis == .horizontal })?.kind, .object)
    }

    func testNoSnapOutsideThreshold() {
        let doc = Document(size: Size2(200, 300))
        let r = Snapper.snap(moving: Rect2(x: 60, y: 60, width: 10, height: 10), others: [], document: doc, settings: SnapSettings(threshold: 1))
        XCTAssertEqual(r.delta, Point(0, 0))
        XCTAssertTrue(r.lines.isEmpty)
    }

    func testGridSnapAndSettingsToggle() {
        let doc = Document(size: Size2(200, 300))
        let s = SnapSettings(threshold: 2, toGuides: false, toCanvas: false, toObjects: false, gridSpacing: 5)
        let r = Snapper.snap(moving: Rect2(x: 11.2, y: 22.9, width: 3, height: 3), others: [], document: doc, settings: s)
        // x edges 11.2, 12.7, 14.2: the right edge 14.2 is 0.8 from the line at 15, the closest of all.
        XCTAssertEqual(r.delta.x, 0.8, accuracy: 1e-9)
        // y edges 22.9, 24.4, 25.9: the middle one is 0.6 from the line at 25.
        XCTAssertEqual(r.delta.y, 0.6, accuracy: 1e-9)
        XCTAssertTrue(r.lines.allSatisfy { $0.kind == .grid })
    }

    // MARK: Rulers

    func testRulerStepsAreNiceAndLabelled() {
        let ticks = RulerScale.ticks(range: 0...100, pixelsPerMM: 4, unit: .millimetres, dpi: 300)
        let majors = ticks.filter { $0.isMajor }
        XCTAssertGreaterThan(majors.count, 3)
        let gaps = zip(majors, majors.dropFirst()).map { $1.position - $0.position }
        XCTAssertTrue(gaps.allSatisfy { abs($0 - gaps[0]) < 1e-9 })
        XCTAssertGreaterThanOrEqual(gaps[0] * 4, 60 - 1e-9, "labels at least 60 points apart")
        XCTAssertTrue([1.0, 2, 5, 10, 20, 50, 100].contains(where: { abs($0 - gaps[0]) < 1e-9 }))
        XCTAssertEqual(majors.first?.label, "0")
    }

    func testRulerInInchesAndZoomedOut() {
        let inch = RulerScale.ticks(range: 0...254, pixelsPerMM: 3, unit: .inches, dpi: 300)
        XCTAssertTrue(inch.filter { $0.isMajor }.allSatisfy { ($0.label ?? "").count > 0 })
        // major ticks sit on whole steps of an inch
        for t in inch where t.isMajor { XCTAssertEqual((t.position / 25.4 * 100).rounded() / 100, t.position / 25.4, accuracy: 1e-6) }

        let far = RulerScale.ticks(range: 0...3000, pixelsPerMM: 0.2, unit: .millimetres, dpi: 300)
        XCTAssertLessThan(far.count, 200, "zoomed out must not produce thousands of ticks")
    }

    func testRulerPixelsUseDPI() {
        let ticks = RulerScale.ticks(range: 0...25.4, pixelsPerMM: 10, unit: .pixels, dpi: 300)
        let labels = ticks.compactMap { $0.label }
        XCTAssertFalse(labels.isEmpty)
        XCTAssertEqual(ticks.first(where: { $0.label == "0" })?.position ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: Align and distribute

    func testAlign() {
        let rects = [Rect2(x: 0, y: 0, width: 10, height: 10), Rect2(x: 30, y: 5, width: 20, height: 10)]
        XCTAssertEqual(Arrange.align(rects, edge: .left), [Point(0, 0), Point(-30, 0)])
        XCTAssertEqual(Arrange.align(rects, edge: .right), [Point(40, 0), Point(0, 0)])
        XCTAssertEqual(Arrange.align(rects, edge: .centerY), [Point(0, 2.5), Point(0, -2.5)])
        XCTAssertEqual(Arrange.align(rects, edge: .top, reference: Rect2(x: 0, y: 100, width: 5, height: 5)), [Point(0, 100), Point(0, 95)])
    }

    func testDistributeEqualGaps() {
        let rects = [Rect2(x: 0, y: 0, width: 10, height: 10), Rect2(x: 12, y: 0, width: 20, height: 10), Rect2(x: 90, y: 0, width: 10, height: 10)]
        let moves = Arrange.distribute(rects, axis: .horizontal)
        let placed = zip(rects, moves).map { $0.offsetBy(dx: $1.x, dy: $1.y) }.sorted { $0.minX < $1.minX }
        XCTAssertEqual(placed[1].minX - placed[0].maxX, placed[2].minX - placed[1].maxX, accuracy: 1e-9)
        XCTAssertEqual(placed[0].minX, 0, accuracy: 1e-9)
        XCTAssertEqual(placed[2].maxX, 100, accuracy: 1e-9)
    }

    func testDistributeNeedsThree() {
        let moves = Arrange.distribute([Rect2(x: 0, y: 0, width: 1, height: 1), Rect2(x: 5, y: 0, width: 1, height: 1)], axis: .horizontal)
        XCTAssertEqual(moves, [Point(0, 0), Point(0, 0)])
    }

    // MARK: Numeric placement

    func testSetFrameIsExactToHundredthOfAMillimetre() {
        let l = shape("a", Rect2(x: 12, y: 7, width: 33, height: 21))
        var doc = Document(size: Size2(300, 400), layers: [l])
        XCTAssertTrue(doc.setFrame(of: l.id, to: Rect2(x: 25.123, y: 40.006, width: 80.554, height: 10)))
        let b = doc.worldBounds(of: l.id)!
        XCTAssertEqual(b.x, 25.12, accuracy: 1e-9)
        XCTAssertEqual(b.y, 40.01, accuracy: 1e-9)
        XCTAssertEqual(b.width, 80.55, accuracy: 1e-9)
        XCTAssertEqual(b.height, 10, accuracy: 1e-9)
    }

    func testSetFrameInsideScaledGroup() {
        let inner = shape("inner", Rect2(x: 5, y: 5, width: 10, height: 10))
        let g = Layer(name: "g", content: .group([inner]), transform: Transform2D.scale(2, 2).then(.translation(100, 100)))
        var doc = Document(size: Size2(400, 400), layers: [g])
        XCTAssertTrue(doc.setFrame(of: inner.id, to: Rect2(x: 150, y: 120, width: 40, height: 30)))
        let b = doc.worldBounds(of: inner.id)!
        XCTAssertEqual(b.x, 150, accuracy: 1e-9)
        XCTAssertEqual(b.y, 120, accuracy: 1e-9)
        XCTAssertEqual(b.width, 40, accuracy: 1e-9)
        XCTAssertEqual(b.height, 30, accuracy: 1e-9)
    }

    func testTranslateMovesInCanvasSpaceEvenInsideRotatedGroup() {
        let inner = shape("inner", Rect2(x: 0, y: 0, width: 10, height: 10))
        let g = Layer(name: "g", content: .group([inner]), transform: Transform2D.rotation(.pi / 2).then(.translation(50, 50)))
        var doc = Document(size: Size2(200, 200), layers: [g])
        let before = doc.worldBounds(of: inner.id)!
        doc.translate([inner.id], by: [Point(7, -3)])
        let after = doc.worldBounds(of: inner.id)!
        XCTAssertEqual(after.x - before.x, 7, accuracy: 1e-9)
        XCTAssertEqual(after.y - before.y, -3, accuracy: 1e-9)
    }

    func testEditThroughStoreUndoes() {
        let l = shape("a", Rect2(x: 0, y: 0, width: 10, height: 10))
        let store = DocumentStore(document: Document(size: Size2(100, 100), layers: [l]))
        store.perform("Align") { doc in
            let moves = Arrange.align([doc.worldBounds(of: l.id)!], edge: .right, reference: doc.canvas)
            doc.translate([l.id], by: moves)
        }
        XCTAssertEqual(store.document.worldBounds(of: l.id)?.maxX ?? 0, 100, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(store.document.worldBounds(of: l.id)?.maxX ?? 0, 10, accuracy: 1e-9)
    }
}
