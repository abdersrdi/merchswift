import XCTest
@testable import CutLine

final class CutLineTests: XCTestCase {
    /// A filled disc of the given radius centred in a square image.
    private func disc(size: Int, radius: Double) -> AlphaImage {
        var a = [UInt8](repeating: 0, count: size * size)
        let c = Double(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
                if (dx * dx + dy * dy).squareRoot() <= radius { a[y * size + x] = 255 }
            }
        }
        return AlphaImage(width: size, height: size, alpha: a)
    }

    private func radii(_ path: CutPath, centre: Point) -> [Double] {
        path.contours[0].flattened(perSegment: 12).map { ($0 - centre).length }
    }

    func testDiscOffsetIsExact() throws {
        let img = disc(size: 240, radius: 60)
        let path = try CutLineGenerator.generate(from: img, options: CutLineOptions(offset: 20))
        XCTAssertEqual(path.contours.count, 1)
        let r = radii(path, centre: Point(120, 120))
        XCTAssertEqual(r.min()!, 80, accuracy: 1.0)
        XCTAssertEqual(r.max()!, 80, accuracy: 1.0)
    }

    func testCurveStaysCloseToTracedOutline() throws {
        // A circle fitted with a 0.35 px tolerance must not wobble more than about a pixel.
        let img = disc(size: 400, radius: 140)
        let path = try CutLineGenerator.generate(from: img, options: CutLineOptions(offset: 12))
        let r = radii(path, centre: Point(200, 200))
        XCTAssertLessThan(r.max()! - r.min()!, 1.5)
        XCTAssertLessThan(path.segmentCount, 120, "a circle should need few curve segments")
    }

    func testOutlineIsClosedAndContinuous() throws {
        let img = disc(size: 200, radius: 50)
        let path = try CutLineGenerator.generate(from: img, options: CutLineOptions(offset: 10))
        for contour in path.contours {
            for i in 0..<contour.segments.count {
                let a = contour.segments[i], b = contour.segments[(i + 1) % contour.segments.count]
                XCTAssertLessThan((a.p3 - b.p0).length, 1e-6)
            }
        }
    }

    func testNoSelfIntersections() throws {
        // A plus shape has concave corners, which is where a naive offset tends to cross itself.
        let n = 300
        var a = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n { for x in 0..<n {
            let inV = x > 130 && x < 170 && y > 40 && y < 260
            let inH = y > 130 && y < 170 && x > 40 && x < 260
            if inV || inH { a[y * n + x] = 255 }
        } }
        let path = try CutLineGenerator.generate(from: AlphaImage(width: n, height: n, alpha: a),
                                                 options: CutLineOptions(offset: 18, smoothing: 6))
        XCTAssertEqual(path.contours.count, 1)
        XCTAssertFalse(path.hasSelfIntersections())
    }

    func testHolesAreIgnored() throws {
        // A ring: the cut line goes around the outside only, with a single contour.
        let size = 240
        var a = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size {
            let d = (Double(x) + 0.5 - 120, Double(y) + 0.5 - 120)
            let r = (d.0 * d.0 + d.1 * d.1).squareRoot()
            if r <= 80 && r >= 40 { a[y * size + x] = 255 }
        } }
        let path = try CutLineGenerator.generate(from: AlphaImage(width: size, height: size, alpha: a),
                                                 options: CutLineOptions(offset: 10))
        XCTAssertEqual(path.contours.count, 1)
        XCTAssertEqual(radii(path, centre: Point(120, 120)).min()!, 90, accuracy: 1.0)
    }

    func testNearbyPiecesMergeAndFarPiecesStaySeparate() throws {
        let w = 400, h = 160
        var a = [UInt8](repeating: 0, count: w * h)
        func box(_ x0: Int, _ x1: Int) { for y in 50..<110 { for x in x0..<x1 { a[y * w + x] = 255 } } }
        box(20, 80); box(90, 150)          // 10 px apart: an offset of 20 joins them
        box(300, 360)                      // far away: stays its own piece
        let path = try CutLineGenerator.generate(from: AlphaImage(width: w, height: h, alpha: a),
                                                 options: CutLineOptions(offset: 20))
        XCTAssertEqual(path.contours.count, 2)
    }

    func testDustIsIgnored() throws {
        var img = disc(size: 300, radius: 80)
        img.alpha[5 * 300 + 5] = 255
        let path = try CutLineGenerator.generate(from: img, options: CutLineOptions(offset: 8))
        XCTAssertEqual(path.contours.count, 1)
    }

    func testEmptyArtworkThrows() {
        let img = AlphaImage(width: 50, height: 50, alpha: [UInt8](repeating: 0, count: 2500))
        XCTAssertThrowsError(try CutLineGenerator.generate(from: img, options: CutLineOptions(offset: 5)))
    }

    func testSVGAndDXF() throws {
        let img = disc(size: 200, radius: 50)
        let px = try CutLineGenerator.generate(from: img, options: CutLineOptions(offset: 10))
        let mm = px.scaled(by: 25.4 / 300)

        let svg = SVGWriter.svg(cut: mm, widthMM: 16.93, heightMM: 16.93)
        XCTAssertTrue(svg.contains("id=\"CutContour\""))
        XCTAssertTrue(svg.contains("viewBox=\"0 0 16.93 16.93\""))
        XCTAssertTrue(svg.contains("C"))
        XCTAssertTrue(svg.contains("Z"))

        let dxf = DXFWriter.dxf(cut: mm.flippedY(height: 16.93))
        XCTAssertTrue(dxf.hasPrefix("0\nSECTION\n"))
        XCTAssertTrue(dxf.hasSuffix("0\nEOF\n"))
        XCTAssertTrue(dxf.contains("POLYLINE"))
        XCTAssertTrue(dxf.contains("CutContour"))
        XCTAssertGreaterThan(dxf.components(separatedBy: "VERTEX").count, 40)
    }

    func testDXFFlatteningStaysWithinTolerance() throws {
        let img = disc(size: 240, radius: 60)
        let px = try CutLineGenerator.generate(from: img, options: CutLineOptions(offset: 20))
        let mm = px.scaled(by: 25.4 / 300)
        let poly = DXFWriter.flatten(mm.contours[0], tolerance: 0.01)
        let centre = Point(120, 120) * (25.4 / 300)
        let expected = 80 * (25.4 / 300)
        for p in poly { XCTAssertEqual((p - centre).length, expected, accuracy: 0.1) }
    }
}
