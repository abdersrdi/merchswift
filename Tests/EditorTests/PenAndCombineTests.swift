import XCTest
import CutLine
import DocumentModel
@testable import Editor

final class PenPathTests: XCTestCase {
    private func assertNear(_ a: Point, _ b: Point, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testClicksMakeStraightSegments() {
        var pen = PenPath()
        pen.addAnchor(at: Point(0, 0)); pen.addAnchor(at: Point(10, 0)); pen.addAnchor(at: Point(10, 10))
        let path = pen.toPathData()
        XCTAssertEqual(path.elements, [.move(Point(0, 0)), .line(Point(10, 0)), .line(Point(10, 10))])
        pen.close()
        XCTAssertEqual(pen.toPathData().elements.last, .close)
        XCTAssertEqual(pen.toPathData().closedSubpathCount, 1)
    }

    func testDraggingPullsOutMirroredHandles() {
        var pen = PenPath()
        pen.addAnchor(at: Point(0, 0))
        pen.addAnchor(at: Point(20, 0))
        pen.dragHandle(to: Point(25, 5))
        XCTAssertEqual(pen.anchors[1].handleOut, Point(25, 5))
        XCTAssertEqual(pen.anchors[1].handleIn, Point(15, -5))
        XCTAssertEqual(pen.anchors[1].kind, .symmetric)
        // The segment into the dragged anchor is a curve using its incoming handle.
        guard case .cubic(let c1, let c2, let end) = pen.toPathData().elements[1] else { return XCTFail("expected a curve") }
        assertNear(c1, Point(0, 0)); assertNear(c2, Point(15, -5)); assertNear(end, Point(20, 0))
    }

    func testDragWithoutMovementStaysCorner() {
        var pen = PenPath()
        pen.addAnchor(at: Point(5, 5))
        pen.dragHandle(to: Point(5, 5))
        XCTAssertEqual(pen.anchors[0].kind, .corner)
        XCTAssertNil(pen.anchors[0].handleOut)
    }

    func testCloseByClickingNearTheStart() {
        var pen = PenPath()
        pen.addAnchor(at: Point(0, 0)); pen.addAnchor(at: Point(10, 0))
        XCTAssertFalse(pen.isNearStart(Point(0.5, 0.5), threshold: 2), "needs three points to close")
        pen.addAnchor(at: Point(10, 10))
        XCTAssertTrue(pen.isNearStart(Point(0.5, 0.5), threshold: 2))
        XCTAssertFalse(pen.isNearStart(Point(5, 5), threshold: 2))
    }

    func testPathDataRoundTrip() {
        var pen = PenPath()
        pen.addAnchor(at: Point(0, 0))
        pen.addAnchor(at: Point(30, 0)); pen.dragHandle(to: Point(36, 8))
        pen.addAnchor(at: Point(30, 30))
        pen.addAnchor(at: Point(0, 30)); pen.dragHandle(to: Point(-6, 22))
        pen.close()
        let back = PenPath(pathData: pen.toPathData())
        XCTAssertEqual(back.toPathData(), pen.toPathData())
        XCTAssertEqual(back.anchors.count, 4)
        XCTAssertTrue(back.isClosed)
        XCTAssertEqual(back.anchors[1].kind, .symmetric)
    }

    func testEllipseReadsBackAsFourSmoothAnchors() {
        let pen = PenPath(pathData: .ellipse(in: Rect2(x: 0, y: 0, width: 20, height: 10)))
        XCTAssertEqual(pen.anchors.count, 4)
        XCTAssertTrue(pen.isClosed)
        XCTAssertTrue(pen.anchors.allSatisfy { $0.kind == .symmetric || $0.kind == .smooth })
    }

    func testMovingAnAnchorMovesItsHandles() {
        var pen = PenPath(anchors: [PenAnchor(Point(0, 0)), PenAnchor(Point(10, 0), handleIn: Point(8, 0), handleOut: Point(12, 0), kind: .symmetric)])
        pen.moveAnchor(1, to: Point(20, 5))
        XCTAssertEqual(pen.anchors[1].handleIn, Point(18, 5))
        XCTAssertEqual(pen.anchors[1].handleOut, Point(22, 5))
    }

    func testHandleMovementRulesPerKind() {
        var sym = PenPath(anchors: [PenAnchor(Point(0, 0), handleIn: Point(-3, 0), handleOut: Point(3, 0), kind: .symmetric)])
        sym.moveHandle(0, .handleOut, to: Point(0, 6))
        assertNear(sym.anchors[0].handleIn!, Point(0, -6))

        var smooth = PenPath(anchors: [PenAnchor(Point(0, 0), handleIn: Point(-3, 0), handleOut: Point(6, 0), kind: .smooth)])
        smooth.moveHandle(0, .handleOut, to: Point(0, 6))      // direction changes, the other keeps its length 3
        assertNear(smooth.anchors[0].handleIn!, Point(0, -3))

        var corner = PenPath(anchors: [PenAnchor(Point(0, 0), handleIn: Point(-3, 0), handleOut: Point(3, 0), kind: .corner)])
        corner.moveHandle(0, .handleOut, to: Point(0, 6))
        assertNear(corner.anchors[0].handleIn!, Point(-3, 0))
    }

    func testInsertingAnAnchorKeepsTheShape() {
        let original = PenPath(anchors: [PenAnchor(Point(0, 0), handleOut: Point(0, 20), kind: .corner),
                                         PenAnchor(Point(30, 0), handleIn: Point(30, 20), kind: .corner)])
        var pen = original
        let at = pen.insertAnchor(afterSegment: 0, at: 0.3)
        XCTAssertEqual(at, 1)
        XCTAssertEqual(pen.anchors.count, 3)
        // Sample both paths: every point of the new path lies on the old curve.
        func samples(_ p: PenPath) -> [Point] { p.toPathData().flattened(curveSteps: 200).flatMap { $0.points } }
        let old = original.toPathData().flattened(curveSteps: 2000).flatMap { $0.points }
        for q in samples(pen) {
            let nearest = old.map { ($0 - q).length }.min()!
            XCTAssertLessThan(nearest, 0.05)
        }
        XCTAssertEqual(pen.anchors[1].kind, .smooth)
    }

    func testInsertingOnAStraightSegmentStaysStraight() {
        var pen = PenPath(anchors: [PenAnchor(Point(0, 0)), PenAnchor(Point(10, 0))])
        pen.insertAnchor(afterSegment: 0, at: 0.5)
        XCTAssertEqual(pen.anchors[1].position, Point(5, 0))
        XCTAssertNil(pen.anchors[1].handleIn)
        XCTAssertEqual(pen.toPathData().elements, [.move(Point(0, 0)), .line(Point(5, 0)), .line(Point(10, 0))])
        XCTAssertNil(pen.insertAnchor(afterSegment: 2, at: 0.5), "an open path has no segment after its last point")
    }

    func testDeleteAndToggle() {
        var pen = PenPath(anchors: [PenAnchor(Point(0, 0)), PenAnchor(Point(10, 0)), PenAnchor(Point(10, 10)), PenAnchor(Point(0, 10))], isClosed: true)
        pen.toggleSmooth(1)
        XCTAssertEqual(pen.anchors[1].kind, .smooth)
        XCTAssertNotNil(pen.anchors[1].handleIn)
        XCTAssertNotNil(pen.anchors[1].handleOut)
        pen.toggleSmooth(1)
        XCTAssertEqual(pen.anchors[1].kind, .corner)
        XCTAssertNil(pen.anchors[1].handleOut)
        pen.deleteAnchor(3)
        XCTAssertEqual(pen.anchors.count, 3)
        XCTAssertTrue(pen.isClosed)
        pen.deleteAnchor(0)
        XCTAssertFalse(pen.isClosed, "two points cannot stay closed")
    }

    func testHitTestPriority() {
        let pen = PenPath(anchors: [PenAnchor(Point(0, 0), handleOut: Point(10, 0)),
                                    PenAnchor(Point(30, 0), handleIn: Point(20, 0))])
        XCTAssertEqual(pen.hitTest(Point(10.2, 0.1), tolerance: 1), .handleOut(0))
        XCTAssertEqual(pen.hitTest(Point(19.8, 0), tolerance: 1), .handleIn(1))
        XCTAssertEqual(pen.hitTest(Point(0.3, 0.2), tolerance: 1), .anchor(0))
        guard case .segment(let i, let t)? = pen.hitTest(Point(15, 0.4), tolerance: 1) else { return XCTFail("expected a segment hit") }
        XCTAssertEqual(i, 0)
        XCTAssertEqual(t, 0.5, accuracy: 0.02)
        XCTAssertNil(pen.hitTest(Point(15, 8), tolerance: 1))
    }
}

final class CombineTests: XCTestCase {
    private func shape(_ name: String, _ r: Rect2, fill: RGBA = .black) -> Layer {
        Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: r.width, height: r.height)), fill: fill)),
              transform: .translation(r.x, r.y))
    }

    func testUnionCreatesOneLayerWithTheLowestStyle() throws {
        let a = shape("a", Rect2(x: 0, y: 0, width: 10, height: 10), fill: RGBA(1, 0, 0))
        let b = shape("b", Rect2(x: 5, y: 0, width: 10, height: 10), fill: RGBA(0, 1, 0))
        var doc = Document(size: Size2(100, 100), layers: [a, b])
        let id = try XCTUnwrap(doc.combine([b.id, a.id], .union))      // selection order must not matter
        XCTAssertEqual(doc.layers.count, 1)
        guard case .shape(let s) = doc.layer(id: id)!.content else { return XCTFail() }
        XCTAssertEqual(s.fill, RGBA(1, 0, 0))
        XCTAssertEqual(abs(s.path.signedArea()), 150, accuracy: 1e-6)
    }

    func testSubtractCutsTheTopLayersOutOfTheBottomOne() throws {
        let base = shape("base", Rect2(x: 0, y: 0, width: 20, height: 20))
        let hole = shape("hole", Rect2(x: 5, y: 5, width: 10, height: 10))
        let other = shape("other", Rect2(x: 50, y: 50, width: 5, height: 5))
        var doc = Document(size: Size2(100, 100), layers: [base, other, hole])
        let id = try XCTUnwrap(doc.combine([base.id, hole.id], .subtract))
        XCTAssertEqual(doc.layers.count, 2)
        XCTAssertEqual(doc.layers.last?.id, id, "the result takes the place of the top source")
        XCTAssertEqual(doc.layers.first?.name, "other")
        XCTAssertEqual(abs(doc.worldPath(of: id)!.signedArea()), 300, accuracy: 1e-6)
    }

    func testRespectsLayerTransforms() throws {
        let a = shape("a", Rect2(x: 0, y: 0, width: 10, height: 10))
        var b = shape("b", Rect2(x: 0, y: 0, width: 10, height: 10))
        b.transform = Transform2D.scale(2, 2).then(.translation(8, 0))      // covers x 8..28, y 0..20
        var doc = Document(size: Size2(100, 100), layers: [a, b])
        let id = try XCTUnwrap(doc.combine([a.id, b.id], .intersect))
        XCTAssertEqual(doc.worldBounds(of: id)?.minX ?? 0, 8, accuracy: 1e-9)
        XCTAssertEqual(doc.worldBounds(of: id)?.maxX ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(doc.worldBounds(of: id)?.height ?? 0, 10, accuracy: 1e-9)
    }

    func testNeedsTwoShapesAndNothingHappensOtherwise() {
        let a = shape("a", Rect2(x: 0, y: 0, width: 10, height: 10))
        let image = Layer(name: "img", content: .image(ImageContent(assetID: "x", size: Size2(5, 5))))
        var doc = Document(size: Size2(100, 100), layers: [a, image])
        let before = doc
        XCTAssertNil(doc.combine([a.id], .union))
        XCTAssertNil(doc.combine([a.id, image.id], .union))
        XCTAssertEqual(doc, before)
    }

    func testEmptyResultLeavesTheDocumentAlone() {
        let a = shape("a", Rect2(x: 0, y: 0, width: 10, height: 10))
        let b = shape("b", Rect2(x: 50, y: 0, width: 10, height: 10))
        var doc = Document(size: Size2(100, 100), layers: [a, b])
        let before = doc
        XCTAssertNil(doc.combine([a.id, b.id], .intersect))
        XCTAssertEqual(doc, before)
    }

    func testCombineIsOneUndoStep() throws {
        let a = shape("a", Rect2(x: 0, y: 0, width: 10, height: 10))
        let b = shape("b", Rect2(x: 5, y: 0, width: 10, height: 10))
        let store = DocumentStore(document: Document(size: Size2(100, 100), layers: [a, b]))
        store.perform("Union") { _ = $0.combine([a.id, b.id], .union) }
        XCTAssertEqual(store.document.layers.count, 1)
        store.undo()
        XCTAssertEqual(store.document.layers.count, 2)
    }

    func testPenPathBecomesALayer() {
        var pen = PenPath()
        for p in [Point(10, 10), Point(40, 10), Point(25, 40)] { pen.addAnchor(at: p) }
        pen.close()
        var doc = Document(size: Size2(100, 100))
        let id = doc.addShape(from: pen, name: "Triangle")
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.worldBounds(of: id)?.width ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(abs(doc.worldPath(of: id)!.signedArea()), 450, accuracy: 1e-6)
    }
}
