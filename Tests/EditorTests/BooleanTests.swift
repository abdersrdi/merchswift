import XCTest
import CutLine
import DocumentModel
@testable import Editor

final class BooleanTests: XCTestCase {
    private func square(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PathData {
        .rect(Rect2(x: x, y: y, width: w, height: h))
    }

    private func area(_ p: PathData) -> Double { abs(p.signedArea()) }

    private func op(_ o: BooleanOperation, _ a: PathData, _ b: PathData) -> PathData { PathBoolean.perform(o, subject: a, clip: b) }

    // MARK: Overlapping rectangles

    func testUnionOfOverlappingSquares() {
        let r = op(.union, square(0, 0, 10, 10), square(5, 5, 10, 10))
        XCTAssertEqual(area(r), 175, accuracy: 1e-6)
        XCTAssertEqual(r.closedSubpathCount, 1)
        XCTAssertEqual(r.bounds?.width ?? 0, 15, accuracy: 1e-9)
    }

    func testIntersectionOfOverlappingSquares() {
        let r = op(.intersect, square(0, 0, 10, 10), square(5, 5, 10, 10))
        XCTAssertEqual(area(r), 25, accuracy: 1e-6)
        XCTAssertEqual(r.closedSubpathCount, 1)
        let b = r.bounds!
        XCTAssertEqual(b.x, 5, accuracy: 1e-9); XCTAssertEqual(b.width, 5, accuracy: 1e-9)
    }

    func testSubtractOfOverlappingSquares() {
        let r = op(.subtract, square(0, 0, 10, 10), square(5, 5, 10, 10))
        XCTAssertEqual(area(r), 75, accuracy: 1e-6)
        XCTAssertEqual(r.closedSubpathCount, 1)
    }

    func testResultOfRectanglesStaysStraightLines() {
        let r = op(.union, square(0, 0, 10, 10), square(5, 0, 10, 10))   // one 15 x 10 rectangle
        XCTAssertEqual(r.closedSubpathCount, 1)
        XCTAssertFalse(r.elements.contains { if case .cubic = $0 { return true } else { return false } }, "corners must not become curves")
        let corners = r.elements.filter { if case .line = $0 { return true } else { return false } }.count
        XCTAssertEqual(corners, 3, "a plain rectangle: a move, three lines and a close")
        XCTAssertEqual(area(r), 150, accuracy: 1e-6)
    }

    // MARK: Holes, separate pieces

    func testSubtractingAnInnerShapeLeavesAHole() {
        let r = op(.subtract, square(0, 0, 20, 20), square(5, 5, 10, 10))
        XCTAssertEqual(abs(r.signedArea()), 300, accuracy: 1e-6)
        XCTAssertEqual(r.closedSubpathCount, 2)
        // A point in the hole is not inside the result, a point in the frame is.
        XCTAssertEqual(windingAt(r, Point(10, 10)), 0)
        XCTAssertNotEqual(windingAt(r, Point(2, 2)), 0)
    }

    func testUnionOfSeparateShapesKeepsBoth() {
        let r = op(.union, square(0, 0, 10, 10), square(30, 0, 10, 10))
        XCTAssertEqual(r.closedSubpathCount, 2)
        XCTAssertEqual(area(r), 200, accuracy: 1e-6)
    }

    func testIntersectOfSeparateShapesIsEmpty() {
        XCTAssertTrue(op(.intersect, square(0, 0, 10, 10), square(30, 0, 10, 10)).elements.isEmpty)
    }

    func testSubtractingAFarShapeChangesNothing() {
        let r = op(.subtract, square(0, 0, 10, 10), square(30, 0, 10, 10))
        XCTAssertEqual(area(r), 100, accuracy: 1e-6)
    }

    func testContainedShapes() {
        let big = square(0, 0, 20, 20), small = square(5, 5, 5, 5)
        XCTAssertEqual(area(op(.union, big, small)), 400, accuracy: 1e-6)
        XCTAssertEqual(area(op(.intersect, big, small)), 25, accuracy: 1e-6)
        XCTAssertTrue(op(.subtract, small, big).elements.isEmpty)
    }

    // MARK: Shared edges

    func testIdenticalShapes() {
        let s = square(0, 0, 10, 10)
        XCTAssertEqual(area(op(.union, s, s)), 100, accuracy: 1e-6)
        XCTAssertEqual(area(op(.intersect, s, s)), 100, accuracy: 1e-6)
        XCTAssertTrue(op(.subtract, s, s).elements.isEmpty)
    }

    func testTouchingSquaresMergeIntoOne() {
        let r = op(.union, square(0, 0, 10, 10), square(10, 0, 10, 10))
        XCTAssertEqual(r.closedSubpathCount, 1)
        XCTAssertEqual(area(r), 200, accuracy: 1e-6)
        XCTAssertEqual(r.elements.filter { if case .line = $0 { return true } else { return false } }.count, 3)
    }

    func testTouchingSquaresDoNotIntersect() {
        XCTAssertTrue(op(.intersect, square(0, 0, 10, 10), square(10, 0, 10, 10)).elements.isEmpty)
        XCTAssertEqual(area(op(.subtract, square(0, 0, 10, 10), square(10, 0, 10, 10))), 100, accuracy: 1e-6)
    }

    func testSubtractSharingAnEdge() {
        // The clip fills the left half of the subject and shares two sides with it.
        let r = op(.subtract, square(0, 0, 10, 10), square(0, 0, 5, 10))
        XCTAssertEqual(area(r), 50, accuracy: 1e-6)
        XCTAssertEqual(r.closedSubpathCount, 1)
    }

    // MARK: Curves and odd input

    func testCircleMinusCircle() {
        let a = PathData.ellipse(in: Rect2(x: 0, y: 0, width: 20, height: 20))
        let b = PathData.ellipse(in: Rect2(x: 10, y: 0, width: 20, height: 20))
        // Area of two radius-10 circles with centres 10 apart: lens = 2 r^2 acos(d/2r) - d/2 sqrt(4r^2 - d^2)
        let r = 10.0, d = 10.0
        let lens = 2 * r * r * acos(d / (2 * r)) - d / 2 * (4 * r * r - d * d).squareRoot()
        let circle = Double.pi * r * r
        XCTAssertEqual(area(op(.intersect, a, b)), lens, accuracy: lens * 0.01)
        XCTAssertEqual(area(op(.union, a, b)), 2 * circle - lens, accuracy: circle * 0.01)
        XCTAssertEqual(area(op(.subtract, a, b)), circle - lens, accuracy: circle * 0.01)
    }

    func testCurvedResultIsCurvesAgain() {
        let a = PathData.ellipse(in: Rect2(x: 0, y: 0, width: 20, height: 20))
        let b = PathData.ellipse(in: Rect2(x: 10, y: 0, width: 20, height: 20))
        let r = op(.union, a, b)
        let curves = r.elements.filter { if case .cubic = $0 { return true } else { return false } }.count
        XCTAssertGreaterThan(curves, 2)
        XCTAssertLessThan(r.elements.count, 60, "re-fitted, not hundreds of tiny lines")
    }

    func testBowTieIsTreatedAsItsTwoTriangles() {
        let bow = PathData(elements: [.move(Point(0, 0)), .line(Point(10, 10)), .line(Point(10, 0)), .line(Point(0, 10)), .close])
        let r = op(.union, bow, square(50, 0, 1, 1))
        XCTAssertEqual(abs(r.signedArea()), 50 + 1, accuracy: 1e-5)
    }

    func testRotatedOverlap() {
        let a = square(0, 0, 10, 10)
        let b = square(-5, -5, 10, 10).transformed(by: Transform2D.rotation(.pi / 4).then(.translation(5, 5)))
        let u = area(op(.union, a, b)), i = area(op(.intersect, a, b))
        XCTAssertEqual(u + i, 100 + 100, accuracy: 1e-4, "union + intersection = both areas")
        XCTAssertGreaterThan(i, 10)
    }

    func testEmptyInputs() {
        XCTAssertEqual(area(op(.union, PathData(), square(0, 0, 4, 4))), 16, accuracy: 1e-6)
        XCTAssertTrue(op(.subtract, PathData(), square(0, 0, 4, 4)).elements.isEmpty)
        XCTAssertEqual(area(op(.subtract, square(0, 0, 4, 4), PathData())), 16, accuracy: 1e-6)
    }

    func testManySidedShapesFinishQuickly() {
        let a = PathData.ellipse(in: Rect2(x: 0, y: 0, width: 300, height: 300))
        let b = PathData.ellipse(in: Rect2(x: 100, y: 50, width: 300, height: 300))
        measure { _ = op(.union, a, b) }
    }

    // MARK: Helper

    private func windingAt(_ path: PathData, _ p: Point) -> Int {
        var w = 0
        for sub in path.flattened(tolerance: 0.01) where sub.closed {
            let poly = sub.points
            for i in 0..<poly.count {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                let cross = (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
                if a.y <= p.y { if b.y > p.y && cross > 0 { w += 1 } } else if b.y <= p.y && cross < 0 { w -= 1 }
            }
        }
        return w
    }
}
