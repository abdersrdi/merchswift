import XCTest
import CutLine
@testable import DocumentModel

final class DocumentModelTests: XCTestCase {
    private func box(_ name: String, x: Double, y: Double, w: Double, h: Double, fill: Bool = true) -> Layer {
        Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: w, height: h)),
                                                       fill: fill ? .black : nil)),
              transform: .translation(x, y))
    }

    private func assertNear(_ a: Rect2?, _ b: Rect2, accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("missing rect", file: file, line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
    }

    // MARK: Transforms and units

    func testTransformComposeAndInvert() {
        let t = Transform2D.scale(2, 3).then(.rotation(.pi / 6)).then(.translation(10, -4))
        let p = Point(7, 5)
        let back = t.inverted()!.apply(t.apply(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        // then() applies the receiver first.
        let a = Transform2D.translation(5, 0).then(.scale(2, 2))
        XCTAssertEqual(a.apply(Point(1, 1)).x, 12, accuracy: 1e-9)
    }

    func testUnits() {
        let u = UnitConverter(dpi: 300)
        XCTAssertEqual(u.millimetres(from: 1, unit: .inches), 25.4, accuracy: 1e-9)
        XCTAssertEqual(u.millimetres(from: 300, unit: .pixels), 25.4, accuracy: 1e-9)
        XCTAssertEqual(u.value(fromMillimetres: 25.4, unit: .pixels), 300, accuracy: 1e-9)
        XCTAssertEqual(u.value(fromMillimetres: 30, unit: .centimetres), 3, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.snapToPrecision(12.3456), 12.35)
    }

    // MARK: Paths

    func testEllipseBounds() {
        let b = PathData.ellipse(in: Rect2(x: 10, y: 20, width: 40, height: 20)).bounds!
        assertNear(b, Rect2(x: 10, y: 20, width: 40, height: 20), accuracy: 0.05)
    }

    func testFlattenClosedRect() {
        let polys = PathData.rect(Rect2(x: 0, y: 0, width: 4, height: 2)).flattened()
        XCTAssertEqual(polys.count, 1)
        XCTAssertTrue(polys[0].closed)
        XCTAssertEqual(polys[0].points.count, 4)
    }

    func testCutPathBecomesPath() throws {
        var a = [UInt8](repeating: 0, count: 100 * 100)
        for y in 30..<70 { for x in 30..<70 { a[y * 100 + x] = 255 } }
        let cut = try CutLineGenerator.generate(from: AlphaImage(width: 100, height: 100, alpha: a), options: CutLineOptions(offset: 6))
        let path = PathData(cutPath: cut)
        XCTAssertGreaterThan(path.elements.count, 3)
        XCTAssertNotNil(path.bounds)
    }

    // MARK: Document tree

    func testCodableRoundTripKeepsNestedStructure() throws {
        let group = Layer(name: "G", content: .group([box("a", x: 1, y: 2, w: 3, h: 4), box("b", x: 5, y: 6, w: 7, h: 8)]),
                          transform: Transform2D.rotation(0.3).then(.translation(4, 5)), opacity: 0.5, blendMode: .multiply)
        let image = Layer(name: "img", content: .image(ImageContent(assetID: "a1", size: Size2(30, 20))))
        let doc = Document(title: "T", size: Size2(300, 400), dpi: 600, presetID: "tee", layers: [group, image],
                           guides: [Guide(axis: .vertical, position: 150)])
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(Document.self, from: data)
        XCTAssertEqual(doc, back)
    }

    func testWorldBoundsThroughGroupTransforms() {
        let inner = box("in", x: 10, y: 0, w: 20, h: 10)
        let g = Layer(name: "g", content: .group([inner]), transform: .translation(100, 50))
        var doc = Document(size: Size2(300, 400), layers: [g])
        assertNear(doc.worldBounds(of: inner.id), Rect2(x: 110, y: 50, width: 20, height: 10))
        doc.update(id: g.id) { $0.transform = Transform2D.scale(2, 2).then(.translation(100, 50)) }
        assertNear(doc.worldBounds(of: inner.id), Rect2(x: 120, y: 50, width: 40, height: 20))
    }

    func testInsertRemoveUpdate() {
        let a = box("a", x: 0, y: 0, w: 10, h: 10), b = box("b", x: 20, y: 0, w: 10, h: 10)
        var doc = Document(size: Size2(100, 100), layers: [a])
        XCTAssertTrue(doc.insert(b, at: 0))
        XCTAssertEqual(doc.layers.map { $0.name }, ["b", "a"])
        XCTAssertTrue(doc.update(id: a.id) { $0.name = "A" })
        XCTAssertEqual(doc.layer(id: a.id)?.name, "A")
        XCTAssertEqual(doc.remove(id: b.id)?.name, "b")
        XCTAssertNil(doc.layer(id: b.id))
        XCTAssertFalse(doc.update(id: UUID()) { _ in })
    }

    func testMoveIntoGroupKeepsCanvasPosition() {
        let a = box("a", x: 30, y: 10, w: 10, h: 10)
        let g = Layer(name: "g", content: .group([]), transform: Transform2D.scale(2, 2).then(.translation(100, 100)))
        var doc = Document(size: Size2(400, 400), layers: [a, g])
        let before = doc.worldBounds(of: a.id)!
        XCTAssertTrue(doc.move(id: a.id, toParent: g.id))
        assertNear(doc.worldBounds(of: a.id), before)
        XCTAssertEqual(doc.layer(id: g.id)?.children.count, 1)
        // and back out
        XCTAssertTrue(doc.move(id: a.id, toParent: nil))
        assertNear(doc.worldBounds(of: a.id), before)
    }

    func testCannotMoveGroupIntoItself() {
        let inner = Layer(name: "inner", content: .group([]))
        let outer = Layer(name: "outer", content: .group([inner]))
        var doc = Document(size: Size2(100, 100), layers: [outer])
        XCTAssertFalse(doc.move(id: outer.id, toParent: inner.id))
        XCTAssertFalse(doc.move(id: outer.id, toParent: outer.id))
    }

    func testGroupAndUngroup() {
        let a = box("a", x: 0, y: 0, w: 10, h: 10), b = box("b", x: 20, y: 0, w: 10, h: 10), c = box("c", x: 40, y: 0, w: 10, h: 10)
        var doc = Document(size: Size2(100, 100), layers: [a, b, c])
        let gid = doc.group(ids: [a.id, c.id])!
        XCTAssertEqual(doc.layers.map { $0.name }, ["b", "Group"])
        XCTAssertEqual(doc.layer(id: gid)?.children.map { $0.name }, ["a", "c"])
        XCTAssertTrue(doc.update(id: gid) { $0.transform = .translation(5, 5) })
        let aWorld = doc.worldBounds(of: a.id)!
        XCTAssertTrue(doc.ungroup(id: gid))
        XCTAssertEqual(doc.layers.count, 3)
        assertNear(doc.worldBounds(of: a.id), aWorld)
    }

    // MARK: Hit testing

    func testHitTestPicksTopmostVisibleUnlocked() {
        let bottom = box("bottom", x: 0, y: 0, w: 50, h: 50)
        var top = box("top", x: 10, y: 10, w: 20, h: 20)
        var doc = Document(size: Size2(100, 100), layers: [bottom, top])
        XCTAssertEqual(doc.hitTest(Point(15, 15)), top.id)
        XCTAssertEqual(doc.hitTest(Point(40, 40)), bottom.id)
        XCTAssertNil(doc.hitTest(Point(80, 80)))

        top.isLocked = true
        doc.update(id: top.id) { $0.isLocked = true }
        XCTAssertEqual(doc.hitTest(Point(15, 15)), bottom.id)
        XCTAssertEqual(doc.hitTest(Point(15, 15), includeLocked: true), top.id)

        doc.update(id: top.id) { $0.isLocked = false; $0.isVisible = false }
        XCTAssertEqual(doc.hitTest(Point(15, 15)), bottom.id)
    }

    func testHitTestRotatedAndGrouped() {
        let inner = box("inner", x: 0, y: 0, w: 40, h: 4)
        let g = Layer(name: "g", content: .group([inner]), transform: Transform2D.rotation(.pi / 2).then(.translation(50, 10)))
        let doc = Document(size: Size2(100, 100), layers: [g])
        // After a quarter turn the 40 x 4 bar stands upright from (50,10) downward, 4 wide to the left.
        XCTAssertEqual(doc.hitTest(Point(48, 30)), inner.id)
        XCTAssertNil(doc.hitTest(Point(60, 30)))
    }

    func testHitTestStrokeOnlyShape() {
        let line = Layer(name: "line", content: .shape(ShapeContent(
            path: PathData(elements: [.move(Point(0, 0)), .line(Point(100, 0))]), stroke: Stroke(color: .black, width: 2))))
        let doc = Document(size: Size2(100, 100), layers: [line])
        XCTAssertEqual(doc.hitTest(Point(50, 0.8)), line.id)
        XCTAssertNil(doc.hitTest(Point(50, 3)))
        XCTAssertEqual(doc.hitTest(Point(50, 3), tolerance: 2.5), line.id)
    }

    func testHitTestHoleInEvenShapeIsNotFilledForNonZeroUnlessWoundTheSame() {
        // A ring built from an outer and an inner square wound the opposite way leaves a real hole.
        let outer: [PathData.Element] = [.move(Point(0, 0)), .line(Point(40, 0)), .line(Point(40, 40)), .line(Point(0, 40)), .close]
        let inner: [PathData.Element] = [.move(Point(10, 10)), .line(Point(10, 30)), .line(Point(30, 30)), .line(Point(30, 10)), .close]
        let ring = Layer(name: "ring", content: .shape(ShapeContent(path: PathData(elements: outer + inner), fill: .black)))
        let doc = Document(size: Size2(100, 100), layers: [ring])
        XCTAssertEqual(doc.hitTest(Point(5, 5)), ring.id)
        XCTAssertNil(doc.hitTest(Point(20, 20)))
    }

    // MARK: Performance sanity

    func testLargeDocumentStaysFast() {
        var layers: [Layer] = []
        for i in 0..<200 { layers.append(box("l\(i)", x: Double(i % 20) * 12, y: Double(i / 20) * 30, w: 10, h: 25)) }
        let doc = Document(size: Size2(300, 400), dpi: 600, layers: layers)
        measure {
            for i in 0..<1000 { _ = doc.hitTest(Point(Double(i % 240), Double(i % 300))) }
        }
    }
}
