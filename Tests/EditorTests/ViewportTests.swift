import XCTest
import CutLine
import DocumentModel
@testable import Editor

final class ViewportTests: XCTestCase {
    func testScreenCanvasRoundTrip() {
        let v = Viewport(zoom: 3.5, origin: Point(12, -7), viewSize: Size2(1000, 700))
        let p = Point(123.4, 56.7)
        let back = v.screenToCanvas(v.canvasToScreen(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
    }

    func testZoomKeepsAnchorFixed() {
        var v = Viewport(zoom: 2, origin: Point(10, 20), viewSize: Size2(800, 600))
        let anchor = Point(300, 200)
        let before = v.screenToCanvas(anchor)
        v.zoom(by: 1.7, around: anchor)
        let after = v.screenToCanvas(anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-9)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-9)
        XCTAssertEqual(v.zoom, 3.4, accuracy: 1e-9)
    }

    func testZoomIsLimited() {
        var v = Viewport(zoom: 1)
        v.zoom(by: 1e9, around: Point(0, 0))
        XCTAssertEqual(v.zoom, Viewport.maxZoom)
        v.zoom(by: 1e-12, around: Point(0, 0))
        XCTAssertEqual(v.zoom, Viewport.minZoom)
    }

    func testPanMovesContentWithTheFinger() {
        var v = Viewport(zoom: 4, origin: Point(0, 0))
        let before = v.canvasToScreen(Point(10, 10))
        v.pan(byScreen: 25, -10)
        let after = v.canvasToScreen(Point(10, 10))
        XCTAssertEqual(after.x - before.x, 25, accuracy: 1e-9)
        XCTAssertEqual(after.y - before.y, -10, accuracy: 1e-9)
    }

    func testFitCentresTheCanvas() {
        var v = Viewport(viewSize: Size2(1000, 800))
        let canvas = Rect2(x: 0, y: 0, width: 300, height: 400)
        v.fit(canvas, padding: 20)
        let tl = v.canvasToScreen(Point(0, 0)), br = v.canvasToScreen(Point(300, 400))
        XCTAssertEqual(tl.x + br.x, 1000, accuracy: 1e-6)
        XCTAssertEqual(tl.y + br.y, 800, accuracy: 1e-6)
        XCTAssertEqual(br.y - tl.y, 760, accuracy: 1e-6, "height limits the fit")
    }

    func testClampKeepsCanvasReachable() {
        var v = Viewport(zoom: 2, origin: Point(5000, -5000), viewSize: Size2(800, 600))
        v.clamp(to: Rect2(x: 0, y: 0, width: 300, height: 400), margin: 80)
        let visible = v.visibleCanvasRect
        XCTAssertTrue(visible.intersects(Rect2(x: 0, y: 0, width: 300, height: 400)))
        XCTAssertLessThanOrEqual(v.origin.x, 300 - 40 + 1e-9)
    }
}

final class TileGridTests: XCTestCase {
    func testLevelFollowsZoomAndIsCappedByDPI() {
        XCTAssertEqual(TileGrid.level(screenPixelsPerMM: 1, documentDPI: 300), 0)
        XCTAssertEqual(TileGrid.level(screenPixelsPerMM: 1.01, documentDPI: 300), 1)
        XCTAssertEqual(TileGrid.level(screenPixelsPerMM: 6, documentDPI: 600), 3)
        // 600 dpi = 23.6 px/mm, so nothing deeper than level 5 is useful
        XCTAssertEqual(TileGrid.level(screenPixelsPerMM: 500, documentDPI: 600), 5)
        XCTAssertEqual(TileGrid.level(screenPixelsPerMM: 500, documentDPI: 300), 4)
        XCTAssertEqual(TileGrid.level(screenPixelsPerMM: 0.001, documentDPI: 300), TileGrid.minLevel)
    }

    func testTileRectsTileTheCanvasWithoutGaps() {
        let level = 1
        let r0 = TileGrid.rect(of: TileKey(level: level, x: 0, y: 0))
        let r1 = TileGrid.rect(of: TileKey(level: level, x: 1, y: 0))
        XCTAssertEqual(r0.width, 256)
        XCTAssertEqual(r1.minX, r0.maxX)
    }

    func testVisibleTilesAreClippedToCanvas() {
        let canvas = Rect2(x: 0, y: 0, width: 300, height: 400)
        // level 0: 512 mm tiles, the whole canvas is one tile
        XCTAssertEqual(TileGrid.visibleTiles(visible: Rect2(x: -100, y: -100, width: 2000, height: 2000), canvas: canvas, level: 0).count, 1)
        // level 2: 128 mm tiles: x 0..300 -> 3 columns, y 0..400 -> 4 rows
        let tiles = TileGrid.visibleTiles(visible: Rect2(x: -50, y: -50, width: 1000, height: 1000), canvas: canvas, level: 2)
        XCTAssertEqual(tiles.count, 12)
        XCTAssertEqual(Set(tiles.map { $0.x }), [0, 1, 2])
        XCTAssertEqual(Set(tiles.map { $0.y }), [0, 1, 2, 3])
    }

    func testVisibleTilesOfASmallWindow() {
        let canvas = Rect2(x: 0, y: 0, width: 300, height: 400)
        let t = TileGrid.visibleTiles(visible: Rect2(x: 130, y: 130, width: 10, height: 10), canvas: canvas, level: 2)
        XCTAssertEqual(t, [TileKey(level: 2, x: 1, y: 1)])
    }

    func testNothingVisibleOutsideTheCanvas() {
        let canvas = Rect2(x: 0, y: 0, width: 300, height: 400)
        XCTAssertTrue(TileGrid.visibleTiles(visible: Rect2(x: 500, y: 0, width: 100, height: 100), canvas: canvas, level: 2).isEmpty)
    }

    func testParentCoversChild() {
        let child = TileKey(level: 3, x: 5, y: 2)
        let parent = TileGrid.parent(of: child)
        XCTAssertEqual(parent, TileKey(level: 2, x: 2, y: 1))
        let pr = TileGrid.rect(of: parent), cr = TileGrid.rect(of: child)
        XCTAssertTrue(pr.contains(Point(cr.minX, cr.minY)) && pr.contains(Point(cr.maxX - 1e-9, cr.maxY - 1e-9)))
        XCTAssertEqual(TileGrid.parent(of: TileKey(level: 1, x: -1, y: -3)), TileKey(level: 0, x: -1, y: -2))
    }

    func testCoveringRectFindsStaleTiles() {
        let stale = TileGrid.tiles(covering: Rect2(x: 120, y: 120, width: 20, height: 20), level: 2)
        XCTAssertEqual(Set(stale), [TileKey(level: 2, x: 0, y: 0), TileKey(level: 2, x: 1, y: 0),
                                    TileKey(level: 2, x: 0, y: 1), TileKey(level: 2, x: 1, y: 1)])
    }
}
