#if canImport(Metal) && canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import CutLine
import DocumentModel
import Editor
import ImageIO
import Metal
import XCTest
@testable import Renderer

/// Converts an IEEE half float, kept as raw bits, to Float (no Float16 type, which Intel Macs lack).
func halfToFloat(_ h: UInt16) -> Float {
    let sign: Float = (h >> 15) & 1 == 1 ? -1 : 1
    let e = Int((h >> 10) & 0x1f), m = Float(h & 0x3ff)
    if e == 0 { return sign * m * Float(pow(2.0, -24.0)) }
    if e == 31 { return m == 0 ? sign * .infinity : .nan }
    return sign * (1 + m / 1024) * Float(pow(2.0, Double(e - 15)))
}

private func pixel(_ t: TilePixels, _ x: Int, _ y: Int) -> (r: Float, g: Float, b: Float, a: Float) {
    let i = (y * TileGrid.tilePixels + x) * 4
    return (halfToFloat(t.data[i]), halfToFloat(t.data[i + 1]), halfToFloat(t.data[i + 2]), halfToFloat(t.data[i + 3]))
}

private func rectLayer(_ name: String, _ r: Rect2, _ color: RGBA, opacity: Double = 1, blend: BlendMode = .normal) -> Layer {
    Layer(name: name, content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: r.width, height: r.height)), fill: color)),
          transform: .translation(r.x, r.y), opacity: opacity, blendMode: blend)
}

private final class TestAssets: AssetProvider {
    var images: [String: CGImage] = [:]
    func image(for assetID: String) -> CGImage? { images[assetID] }
}

final class RasterizerTests: XCTestCase {
    private func tile(_ doc: Document, level: Int = 0, x: Int = 0, y: Int = 0, assets: AssetProvider? = nil) throws -> TilePixels {
        try XCTUnwrap(LayerRasterizer.render(doc, assets: assets, tile: TileKey(level: level, x: x, y: y)))
    }

    func testHalfFloatConversion() {
        XCTAssertEqual(halfToFloat(0x3C00), 1)
        XCTAssertEqual(halfToFloat(0x3800), 0.5)
        XCTAssertEqual(halfToFloat(0), 0)
        XCTAssertEqual(halfToFloat(0xC000), -2)
    }

    func testFilledRectLandsWhereItShouldAndYIsDown() throws {
        let doc = Document(size: Size2(100, 100), layers: [rectLayer("r", Rect2(x: 10, y: 10, width: 20, height: 20), RGBA(1, 0, 0))])
        let t = try tile(doc)      // level 0: 1 px per mm
        let inside = pixel(t, 20, 20), outside = pixel(t, 60, 60), below = pixel(t, 20, 400)
        XCTAssertEqual(inside.r, 1, accuracy: 0.01); XCTAssertEqual(inside.a, 1, accuracy: 0.01); XCTAssertEqual(inside.g, 0, accuracy: 0.01)
        XCTAssertEqual(outside.a, 0, accuracy: 0.01)
        XCTAssertEqual(below.a, 0, accuracy: 0.01, "y grows downward: the rect is near the top of the tile, not the bottom")
        XCTAssertEqual(pixel(t, 9, 20).a, 0, accuracy: 0.01)
        XCTAssertEqual(pixel(t, 30, 20).a, 0, accuracy: 0.02)    // the pixel at x=30 covers 30..31, outside the rect
    }

    func testDensityAndTileOffset() throws {
        let doc = Document(size: Size2(600, 100), layers: [rectLayer("r", Rect2(x: 300, y: 10, width: 10, height: 10), RGBA(0, 1, 0))])
        // level 1: 2 px/mm, 256 mm tiles; tile (1, 0) starts at x = 256 mm.
        let t = try tile(doc, level: 1, x: 1, y: 0)
        XCTAssertEqual(pixel(t, (300 - 256) * 2 + 10, 30).g, 1, accuracy: 0.01)
        XCTAssertEqual(pixel(t, (300 - 256) * 2 - 3, 40).a, 0, accuracy: 0.01)
        XCTAssertEqual(pixel(t, (310 - 256) * 2 + 3, 40).a, 0, accuracy: 0.01)
        let empty = try tile(doc, level: 1, x: 0, y: 0)
        XCTAssertEqual(pixel(empty, 100, 40).a, 0, accuracy: 0.01)
    }

    func testOpacityIsPremultiplied() throws {
        let doc = Document(size: Size2(100, 100), layers: [rectLayer("r", Rect2(x: 0, y: 0, width: 50, height: 50), RGBA(1, 0, 0), opacity: 0.5)])
        let p = pixel(try tile(doc), 20, 20)
        XCTAssertEqual(p.a, 0.5, accuracy: 0.02)
        XCTAssertEqual(p.r, 0.5, accuracy: 0.02)
    }

    func testGroupOpacityAppliesOnceToTheWholeGroup() throws {
        let a = rectLayer("a", Rect2(x: 0, y: 0, width: 40, height: 40), RGBA(1, 0, 0))
        let b = rectLayer("b", Rect2(x: 20, y: 20, width: 40, height: 40), RGBA(1, 0, 0))
        let g = Layer(name: "g", content: .group([a, b]), opacity: 0.5)
        let t = try tile(Document(size: Size2(100, 100), layers: [g]))
        XCTAssertEqual(pixel(t, 30, 30).a, 0.5, accuracy: 0.02, "overlap must not be 0.75")
        XCTAssertEqual(pixel(t, 10, 10).a, 0.5, accuracy: 0.02)
    }

    func testMultiplyBlend() throws {
        let base = rectLayer("base", Rect2(x: 0, y: 0, width: 50, height: 50), RGBA(0.5, 0.5, 0.5))
        let top = rectLayer("top", Rect2(x: 0, y: 0, width: 50, height: 50), RGBA(0.5, 1, 1), blend: .multiply)
        let p = pixel(try tile(Document(size: Size2(100, 100), layers: [base, top])), 25, 25)
        XCTAssertEqual(p.r, 0.25, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.5, accuracy: 0.02)
        XCTAssertEqual(p.a, 1, accuracy: 0.01)
    }

    func testHiddenLayerIsNotDrawn() throws {
        var layer = rectLayer("r", Rect2(x: 0, y: 0, width: 50, height: 50), RGBA(1, 0, 0))
        layer.isVisible = false
        XCTAssertEqual(pixel(try tile(Document(size: Size2(100, 100), layers: [layer])), 20, 20).a, 0, accuracy: 0.01)
    }

    func testTransformsAndGroups() throws {
        let inner = rectLayer("in", Rect2(x: 5, y: 5, width: 10, height: 10), RGBA(0, 0, 1))
        let g = Layer(name: "g", content: .group([inner]), transform: Transform2D.scale(2, 2).then(.translation(100, 0)))
        let t = try tile(Document(size: Size2(300, 100), layers: [g]))
        // world rect: x 110..130, y 10..30
        XCTAssertEqual(pixel(t, 120, 20).b, 1, accuracy: 0.01)
        XCTAssertEqual(pixel(t, 105, 20).a, 0, accuracy: 0.01)
    }

    func testStrokeUsesMillimetreWidth() throws {
        let line = Layer(name: "l", content: .shape(ShapeContent(
            path: PathData(elements: [.move(Point(10, 50)), .line(Point(90, 50))]), stroke: Stroke(color: .black, width: 10))))
        let t = try tile(Document(size: Size2(100, 100), layers: [line]))
        XCTAssertEqual(pixel(t, 50, 47).a, 1, accuracy: 0.02)
        XCTAssertEqual(pixel(t, 50, 53).a, 1, accuracy: 0.02)
        XCTAssertEqual(pixel(t, 50, 40).a, 0, accuracy: 0.02)
    }

    func testImageIsDrawnUpright() throws {
        // 1 x 2 image: top pixel red, bottom pixel blue.
        let space = CGColorSpaceCreateDeviceRGB()
        var bytes: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let image: CGImage = bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: 1, height: 2, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let assets = TestAssets()
        assets.images["a"] = image
        let layer = Layer(name: "img", content: .image(ImageContent(assetID: "a", size: Size2(20, 40))))
        let t = try tile(Document(size: Size2(100, 100), layers: [layer]), assets: assets)
        XCTAssertGreaterThan(pixel(t, 10, 8).r, 0.9, "top of the picture stays on top")
        XCTAssertGreaterThan(pixel(t, 10, 32).b, 0.9)
    }

    func testSixteenBitGradientHasNoBanding() throws {
        // A 0.1 -> 0.2 grey ramp across 400 mm has far more distinct steps in 16 bits than the 25 an 8-bit buffer would give.
        var layers: [Layer] = []
        for i in 0..<400 {
            let v = 0.1 + 0.1 * Double(i) / 399
            layers.append(rectLayer("s\(i)", Rect2(x: Double(i), y: 0, width: 1, height: 10), RGBA(v, v, v)))
        }
        let t = try tile(Document(size: Size2(400, 10), layers: layers))
        var distinct = Set<UInt16>()
        for x in 0..<400 { distinct.insert(t.data[(5 * TileGrid.tilePixels + x) * 4]) }
        XCTAssertGreaterThan(distinct.count, 100)
    }
}

final class CompositorTests: XCTestCase {
    private func makeDevice() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device on this machine") }
        return d
    }

    private func readBack(_ t: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&bytes, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return bytes
    }

    /// BGRA bytes to (r, g, b).
    private func rgb(_ bytes: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i]))
    }

    private func writePNG(_ bytes: [UInt8], width: Int, height: Int, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MERCHSWIFT_PROOF_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var copy = bytes
        let image: CGImage? = copy.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
        }
        guard let image, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/" + name) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func target(_ device: MTLDevice, _ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        d.storageMode = .managed
        #else
        d.storageMode = .shared
        #endif
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func demoDocument() -> Document {
        var layers = [rectLayer("red", Rect2(x: 20, y: 20, width: 40, height: 40), RGBA(0.84, 0.16, 0.2))]
        layers.append(Layer(name: "disc", content: .shape(ShapeContent(path: .ellipse(in: Rect2(x: 50, y: 50, width: 40, height: 40)),
                                                                        fill: RGBA(0.1, 0.4, 0.9), stroke: Stroke(color: .black, width: 2))),
                            opacity: 0.8, blendMode: .multiply))
        return Document(size: Size2(100, 100), dpi: 300, layers: layers)
    }

    func testPaperShapesAndBackgroundAreCompositedCorrectly() throws {
        let device = try makeDevice()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let compositor = try XCTUnwrap(CanvasCompositor(device: device, colorPixelFormat: .bgra8Unorm))
        let cache = TileCache(device: device)
        let doc = demoDocument()
        cache.setDocument(doc, assets: nil)

        var vp = Viewport(viewSize: Size2(400, 400))
        vp.fit(doc.canvas, padding: 20)          // zoom 3.6: canvas spans 20..380
        let level = TileGrid.level(screenPixelsPerMM: vp.zoom, documentDPI: doc.dpi)
        cache.prefetch(TileGrid.visibleTiles(visible: vp.visibleCanvasRect, canvas: doc.canvas, level: level))
        XCTAssertTrue(cache.waitUntilIdle(), "tiles should finish rendering")

        let tex = try target(device, 400, 400)
        let stats = try XCTUnwrap(compositor.render(document: doc, viewport: vp, scale: 1, cache: cache, into: tex, commandQueue: queue))
        XCTAssertGreaterThan(stats.tilesDrawn, 0)
        XCTAssertEqual(stats.tilesMissing, 0)

        let px = readBack(tex)
        writePNG(px, width: 400, height: 400, name: "canvas-composite.png")

        func at(_ canvasX: Double, _ canvasY: Double) -> (Int, Int, Int) {
            let s = vp.canvasToScreen(Point(canvasX, canvasY))
            return rgb(px, 400, Int(s.x), Int(s.y))
        }
        let bg = rgb(px, 400, 2, 2)
        XCTAssertEqual(bg.0, 41, accuracy: 3); XCTAssertEqual(bg.1, 43, accuracy: 3); XCTAssertEqual(bg.2, 48, accuracy: 3)
        let paper = at(10, 80)
        XCTAssertGreaterThan(paper.0, 250); XCTAssertGreaterThan(paper.1, 250); XCTAssertGreaterThan(paper.2, 250)
        let red = at(35, 35)
        XCTAssertEqual(red.0, 214, accuracy: 4); XCTAssertEqual(red.1, 41, accuracy: 4); XCTAssertEqual(red.2, 51, accuracy: 4)
    }

    func testZoomedInRendersAtHigherDensityAndStaysSharp() throws {
        let device = try makeDevice()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let compositor = try XCTUnwrap(CanvasCompositor(device: device, colorPixelFormat: .bgra8Unorm))
        let cache = TileCache(device: device)
        let doc = demoDocument()
        cache.setDocument(doc, assets: nil)

        var vp = Viewport(viewSize: Size2(400, 400))
        vp.fit(doc.canvas, padding: 20)
        vp.zoom(by: 8, around: Point(200, 200))          // zoom 28.8 pt/mm
        let level = TileGrid.level(screenPixelsPerMM: vp.zoom, documentDPI: doc.dpi)
        XCTAssertGreaterThan(level, 3)
        cache.prefetch(TileGrid.visibleTiles(visible: vp.visibleCanvasRect, canvas: doc.canvas, level: level))
        XCTAssertTrue(cache.waitUntilIdle())
        let tex = try target(device, 400, 400)
        let stats = try XCTUnwrap(compositor.render(document: doc, viewport: vp, scale: 1, cache: cache, into: tex, commandQueue: queue))
        XCTAssertEqual(stats.tilesMissing, 0)
        writePNG(readBack(tex), width: 400, height: 400, name: "canvas-zoomed.png")
    }

    func testChangedTileStaysVisibleUntilReplaced() throws {
        let device = try makeDevice()
        let cache = TileCache(device: device)
        var doc = demoDocument()
        cache.setDocument(doc, assets: nil)
        let key = TileKey(level: 2, x: 0, y: 0)
        cache.prefetch([key])
        XCTAssertTrue(cache.waitUntilIdle())
        let first = try XCTUnwrap(cache.texture(for: key))
        XCTAssertTrue(cache.waitUntilIdle())

        doc.layers.removeAll()
        cache.setDocument(doc, assets: nil)
        let stale = cache.texture(for: key)
        XCTAssertNotNil(stale, "the old tile keeps showing while the new one renders")
        XCTAssertTrue(cache.waitUntilIdle())
        let fresh = try XCTUnwrap(cache.texture(for: key))
        XCTAssertFalse(fresh === first)
    }

    func testCacheEvictsOldestTiles() throws {
        let device = try makeDevice()
        let cache = TileCache(device: device, maxTiles: 4)
        cache.setDocument(Document(size: Size2(2000, 2000)), assets: nil)
        let keys = (0..<8).map { TileKey(level: 0, x: $0 % 4, y: $0 / 4) }
        for k in keys { cache.prefetch([k]); XCTAssertTrue(cache.waitUntilIdle()) }
        XCTAssertLessThanOrEqual(cache.cachedCount, 4)
        XCTAssertNotNil(cache.peek(keys.last!))
    }

    func testManyLayersRenderTimes() throws {
        // Not a pass/fail speed claim; it records how long 60 layers take to rasterise a tile on this machine.
        var layers: [Layer] = []
        for i in 0..<60 {
            layers.append(rectLayer("l\(i)", Rect2(x: Double(i % 10) * 28, y: Double(i / 10) * 28, width: 24, height: 24),
                                    RGBA(Double(i % 7) / 7, Double(i % 5) / 5, Double(i % 3) / 3), opacity: 0.8,
                                    blend: i % 2 == 0 ? .multiply : .normal))
        }
        let doc = Document(size: Size2(300, 400), dpi: 600, layers: layers)
        measure { _ = LayerRasterizer.render(doc, assets: nil, tile: TileKey(level: 2, x: 0, y: 0)) }
    }
}

final class OverlayTests: XCTestCase {
    func testLinesAndMarkersAreDrawnAtScreenSize() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device on this machine") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let overlay = try XCTUnwrap(OverlayRenderer(device: device, colorPixelFormat: .bgra8Unorm))

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 200, height: 200, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        d.storageMode = .managed
        #else
        d.storageMode = .shared
        #endif
        let tex = try XCTUnwrap(device.makeTexture(descriptor: d))

        // Zoom 2: canvas (50, 50) is screen (100, 100). A 3-point blue line from canvas x=20 to 80 along y=50,
        // and a 10-point white marker with a red edge at canvas (50, 20) -> screen (100, 40).
        let vp = Viewport(zoom: 2, origin: Point(0, 0), viewSize: Size2(200, 200))
        let items: [OverlayItem] = [
            .polyline([Point(20, 50), Point(80, 50)], closed: false, color: RGBA(0, 0, 1), width: 3, dashed: false),
            .marker(Point(50, 20), shape: .square, size: 10, fill: RGBA(1, 1, 1), stroke: RGBA(1, 0, 0)),
            .rectFill(Rect2(x: 10, y: 70, width: 20, height: 20), color: RGBA(0, 1, 0, 0.5)),
        ]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
        overlay.encode(into: enc, items: items, viewport: vp, device: device)
        enc.endEncoding()
        #if os(macOS)
        if let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: tex); blit.endEncoding() }
        #endif
        cb.commit(); cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: 200 * 200 * 4)
        tex.getBytes(&bytes, bytesPerRow: 800, from: MTLRegionMake2D(0, 0, 200, 200), mipmapLevel: 0)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 200 + x) * 4; return (Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i])) }

        let line = rgb(100, 100)                       // on the line
        XCTAssertEqual(line.2, 255, accuracy: 2); XCTAssertEqual(line.0, 0, accuracy: 2)
        XCTAssertEqual(rgb(100, 106).2, 0, accuracy: 2, "the line is 3 points wide, not 12")
        let centre = rgb(100, 40)                      // marker fill
        XCTAssertGreaterThan(centre.0, 250); XCTAssertGreaterThan(centre.1, 250)
        let edge = rgb(100 - 5 - 1, 40)                // just inside the red outline ring
        XCTAssertGreaterThan(edge.0, 200); XCTAssertLessThan(edge.1, 80)
        let tint = rgb(40, 160)                        // half-transparent green over black
        XCTAssertEqual(tint.1, 128, accuracy: 3); XCTAssertEqual(tint.0, 0, accuracy: 2)
        XCTAssertEqual(rgb(10, 10).0, 0)
    }
}
#endif
