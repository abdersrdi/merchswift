import XCTest
import CutLine
import DocumentModel
@testable import Editor

final class TextWarpTests: XCTestCase {
    /// A block 100 wide with a row of small "letters" standing on a baseline at y = 10.
    private func block() -> PathData {
        var e: [PathData.Element] = []
        for i in 0..<10 {
            let x = Double(i) * 10 + 2
            e += [.move(Point(x, 2)), .line(Point(x + 6, 2)), .line(Point(x + 6, 10)), .line(Point(x, 10)), .close]
        }
        return PathData(elements: e)
    }

    private func points(_ p: PathData) -> [Point] { p.flattened(tolerance: 0.02).flatMap { $0.points } }

    func testZeroBendChangesNothing() {
        let o = block()
        XCTAssertEqual(TextWarp.apply(.arc(degrees: 0), to: o, blockWidth: 100, baseline: 10), o)
    }

    func testArcKeepsTheBaselineOnACircle() {
        let out = TextWarp.apply(.arc(degrees: 90), to: block(), blockWidth: 100, baseline: 10)
        let radius = 100 / (Double.pi / 2)
        let centre = Point(50, 10 + radius)
        // Every point that started on the baseline (y = 10) is now exactly one radius from the centre.
        let original = points(block()).filter { abs($0.y - 10) < 1e-9 }
        XCTAssertFalse(original.isEmpty)
        // Letters standing on the baseline: their bottoms must sit on the circle.
        let bottoms = points(out).filter { abs(($0 - centre).length - radius) < 0.05 }
        XCTAssertGreaterThan(bottoms.count, 20)
    }

    func testArcBendsTheEndsDownForPositiveDegrees() {
        let out = TextWarp.apply(.arc(degrees: 120), to: block(), blockWidth: 100, baseline: 10)
        let pts = points(out)
        let leftMost = pts.min { $0.x < $1.x }!, middle = pts.min { abs($0.x - 50) < abs($1.x - 50) }!
        XCTAssertGreaterThan(leftMost.y, middle.y + 5, "a rainbow: the ends hang lower than the middle")
        let smile = points(TextWarp.apply(.arc(degrees: -120), to: block(), blockWidth: 100, baseline: 10))
        let sLeft = smile.min { $0.x < $1.x }!, sMid = smile.min { abs($0.x - 50) < abs($1.x - 50) }!
        XCTAssertLessThan(sLeft.y, sMid.y - 5, "a smile: the ends rise")
    }

    func testArcKeepsLettersUpright() {
        // The letter in the middle stays where it was; letters further out turn.
        let out = TextWarp.apply(.arc(degrees: 90), to: block(), blockWidth: 100, baseline: 10)
        let bounds = out.bounds!
        XCTAssertLessThan(bounds.width, 100, "bending shortens the span")
        XCTAssertGreaterThan(bounds.height, 12, "and lifts the sides out of the baseline row")
    }

    func testBendOutputIsCurvesNotThousandsOfLines() {
        let out = TextWarp.apply(.arc(degrees: 60), to: block(), blockWidth: 100, baseline: 10)
        XCTAssertLessThan(out.elements.count, 400)
        XCTAssertEqual(out.closedSubpathCount, 10)
    }

    func testTextOnAStraightPathIsJustShifted() {
        let track = PathData(elements: [.move(Point(0, 50)), .line(Point(300, 50))])
        let out = TextWarp.apply(.path(track, offset: 20), to: block(), blockWidth: 100, baseline: 10)
        let b = out.bounds!
        XCTAssertEqual(b.minX, 22, accuracy: 0.05)       // first letter starts at x = 2 in the block
        XCTAssertEqual(b.maxX, 20 + 98, accuracy: 0.05)
        XCTAssertEqual(b.minY, 42, accuracy: 0.05)        // letters rise 8 above the baseline, which now sits at y = 50
        XCTAssertEqual(b.maxY, 50, accuracy: 0.05)
    }

    func testTextOnADownwardPathTurnsClockwise() {
        let track = PathData(elements: [.move(Point(100, 0)), .line(Point(100, 300))])
        let out = TextWarp.apply(.path(track, offset: 0), to: block(), blockWidth: 100, baseline: 10)
        let b = out.bounds!
        XCTAssertEqual(b.minX, 100, accuracy: 0.05)       // "up" for the glyphs now points right
        XCTAssertEqual(b.maxX, 108, accuracy: 0.05)
        XCTAssertEqual(b.minY, 2, accuracy: 0.05)
        XCTAssertEqual(b.maxY, 98, accuracy: 0.05)
    }

    func testPathCurveFollowsACorner() {
        let track = PathData(elements: [.move(Point(0, 0)), .line(Point(60, 0)), .line(Point(60, 200))])
        let out = TextWarp.apply(.path(track, offset: 0), to: block(), blockWidth: 100, baseline: 10)
        let b = out.bounds!
        XCTAssertGreaterThan(b.maxY, 30, "the last letters run down the vertical part")
        XCTAssertLessThan(b.minX, 5)
    }

    func testTextThatOvershootsThePathContinuesStraight() {
        let track = PathData(elements: [.move(Point(0, 0)), .line(Point(50, 0))])
        let out = TextWarp.apply(.path(track, offset: 0), to: block(), blockWidth: 100, baseline: 10)
        XCTAssertEqual(out.bounds!.maxX, 98, accuracy: 0.05)
    }

    func testLengthAlongThePathIsPreservedOnACurve() {
        // A quarter circle of radius 100 is 157.08 long: letters spaced 10 apart stay about 10 apart along it.
        let k = 0.5522847498307936
        let track = PathData(elements: [.move(Point(0, 100)), .cubic(Point(0, 100 - 100 * k), Point(100 - 100 * k, 0), Point(100, 0))])
        let out = TextWarp.apply(.path(track, offset: 0), to: block(), blockWidth: 100, baseline: 10)
        let subs = out.flattened(tolerance: 0.02).filter { $0.closed }
        let centres = subs.map { sub in Rect2.bounding(sub.points)!.center }
        XCTAssertEqual(centres.count, 10)
        for i in 1..<centres.count {
            XCTAssertEqual((centres[i] - centres[i - 1]).length, 10, accuracy: 0.8)
        }
    }

    func testEmptyOutlineIsFine() {
        XCTAssertTrue(TextWarp.apply(.arc(degrees: 90), to: PathData(), blockWidth: 10, baseline: 5).elements.isEmpty)
    }
}
