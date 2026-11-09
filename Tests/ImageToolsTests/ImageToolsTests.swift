import XCTest
import DocumentModel
import Export
@testable import ImageTools

// MARK: Helpers

private func image(_ w: Int, _ h: Int, _ f: (Int, Int) -> [UInt8]) -> RGBAImage {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w { let c = f(x, y); for k in 0..<4 { px[(y * w + x) * 4 + k] = c[k] } } }
    return RGBAImage(width: w, height: h, pixels: px)
}

private func px(_ i: RGBAImage, _ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(i.pixels[(y * i.width + x) * 4 + $0]) } }

private func disc(_ size: Int, radius: Double, colour: [UInt8] = [255, 0, 0, 255]) -> RGBAImage {
    let c = Double(size) / 2
    return image(size, size) { x, y in
        let d = ((Double(x) + 0.5 - c) * (Double(x) + 0.5 - c) + (Double(y) + 0.5 - c) * (Double(y) + 0.5 - c)).squareRoot()
        return d <= radius ? colour : [0, 0, 0, 0]
    }
}

private func opaqueCount(_ i: RGBAImage, above: Int = 127) -> Int {
    (0..<(i.width * i.height)).filter { Int(i.pixels[$0 * 4 + 3]) > above }.count
}

private func meanAlpha(_ i: RGBAImage) -> Double {
    Double((0..<(i.width * i.height)).reduce(0) { $0 + Int(i.pixels[$1 * 4 + 3]) }) / Double(i.width * i.height) / 255
}

// MARK: Resampling

final class ResamplerTests: XCTestCase {
    func testSizeAndIdentity() {
        let src = image(5, 4) { x, y in [UInt8(x * 40), UInt8(y * 50), 7, 255] }
        let big = Resampler.lanczos(src, toWidth: 11, height: 9)
        XCTAssertEqual(big.width, 11); XCTAssertEqual(big.height, 9)
        XCTAssertEqual(big.pixels.count, 11 * 9 * 4)
        XCTAssertEqual(Resampler.lanczos(src, toWidth: 5, height: 4), src, "same size gives the same picture")
        XCTAssertEqual(Resampler.lanczos(src, scale: 2).width, 10)
    }

    func testFlatColourStaysFlat() {
        let src = image(6, 6) { _, _ in [10, 200, 30, 255] }
        for (w, h) in [(13, 9), (3, 2)] {
            let out = Resampler.lanczos(src, toWidth: w, height: h)
            for i in 0..<(w * h) {
                XCTAssertEqual(Int(out.pixels[i * 4]), 10, accuracy: 1); XCTAssertEqual(Int(out.pixels[i * 4 + 1]), 200, accuracy: 1)
                XCTAssertEqual(Int(out.pixels[i * 4 + 3]), 255)
            }
        }
        let half = image(4, 4) { _, _ in [50, 60, 70, 128] }
        XCTAssertEqual(Int(Resampler.lanczos(half, scale: 3).pixels[3]), 128, accuracy: 1, "constant alpha stays constant")
    }

    func testTransparentEdgesDoNotLeakDarkOrLightFringes() {
        // Red on the left, fully transparent (with black colour data) on the right.
        let src = image(8, 2) { x, _ in x < 4 ? [255, 0, 0, 255] : [0, 0, 0, 0] }
        let out = Resampler.lanczos(src, toWidth: 32, height: 8)
        var seen = 0
        for x in 0..<32 {
            let p = px(out, x, 4)
            if p[3] > 10 && p[3] < 245 {
                seen += 1
                XCTAssertGreaterThan(p[0], 235, "x \(x): the half-transparent edge is still red, not darkened")
                XCTAssertLessThan(p[1], 20)
            }
        }
        XCTAssertGreaterThan(seen, 0, "there is a soft edge to look at")
    }

    func testStepEdgeStaysSharp() {
        let src = image(8, 1) { x, _ in x < 4 ? [0, 0, 0, 255] : [255, 255, 255, 255] }
        let out = Resampler.lanczos(src, toWidth: 32, height: 1)
        let mid = (0..<32).filter { let v = Int(out.pixels[$0 * 4]); return v > 20 && v < 235 }.count
        XCTAssertLessThanOrEqual(mid, 5, "a step edge four times larger is a few pixels wide, not a smear")
        XCTAssertEqual(Int(out.pixels[0]), 0, accuracy: 3)
        XCTAssertEqual(Int(out.pixels[31 * 4]), 255, accuracy: 3)
    }

    func testShrinkingAverages() {
        let src = image(32, 32) { x, y in (x + y) % 2 == 0 ? [0, 0, 0, 255] : [255, 255, 255, 255] }
        let out = Resampler.lanczos(src, toWidth: 8, height: 8)
        for y in 2...5 { for x in 2...5 { XCTAssertEqual(px(out, x, y)[0], 128, accuracy: 8, "a fine checkerboard averages to grey") } }
    }

    func testKernel() {
        XCTAssertEqual(Resampler.kernel(0, lobes: 3), 1)
        XCTAssertEqual(Resampler.kernel(1, lobes: 3), 0, accuracy: 1e-12)
        XCTAssertEqual(Resampler.kernel(3, lobes: 3), 0)
        XCTAssertLessThan(Resampler.kernel(1.5, lobes: 3), 0, "the negative lobe is what keeps edges crisp")
    }
}

// MARK: Filters

final class FilterTests: XCTestCase {
    func testBlurKeepsTotalAndSpreadsAnImpulse() {
        var plane = [Float](repeating: 0, count: 21 * 21)
        plane[10 * 21 + 10] = 100
        let b = Filters.gaussianBlur(plane, width: 21, height: 21, sigma: 2)
        XCTAssertEqual(b.reduce(0, +), 100, accuracy: 0.05)
        XCTAssertLessThan(b[10 * 21 + 10], 30)
        XCTAssertEqual(b[10 * 21 + 8], b[10 * 21 + 12], accuracy: 1e-4, "symmetric")
        XCTAssertEqual(Filters.gaussianBlur(plane, width: 21, height: 21, sigma: 0), plane)
        let flat = [Float](repeating: 0.4, count: 100)
        for v in Filters.gaussianBlur(flat, width: 10, height: 10, sigma: 3) { XCTAssertEqual(v, 0.4, accuracy: 1e-5) }
    }

    func testUnsharpMaskAddsEdgeContrastOnly() {
        let src = image(40, 8) { x, _ in x < 20 ? [80, 80, 80, 255] : [160, 160, 160, 255] }
        let out = Filters.unsharpMask(src, radius: 2, amount: 1)
        XCTAssertGreaterThan(px(out, 20, 4)[0], 165, "the bright side of the edge overshoots")
        XCTAssertLessThan(px(out, 19, 4)[0], 75, "the dark side undershoots")
        XCTAssertEqual(px(out, 2, 4)[0], 80); XCTAssertEqual(px(out, 37, 4)[0], 160)
        let quiet = Filters.unsharpMask(src, radius: 2, amount: 1, threshold: 0.5)
        XCTAssertEqual(quiet, src, "differences below the threshold are left alone")
        XCTAssertEqual(px(out, 20, 4)[3], 255)
    }

    func testVintageTone() {
        let src = image(2, 1) { x, _ in x == 0 ? [0, 0, 0, 255] : [255, 255, 255, 200] }
        XCTAssertEqual(Filters.vintageTone(src, fade: 0, warmth: 0), src)
        let out = Filters.vintageTone(src, fade: 1, warmth: 0.5)
        XCTAssertGreaterThan(px(out, 0, 0)[0], 20, "blacks are lifted")
        XCTAssertLessThan(px(out, 1, 0)[2], 255, "whites are warmed")
        XCTAssertEqual(px(out, 1, 0)[3], 200, "alpha is untouched")
        XCTAssertGreaterThan(px(out, 1, 0)[0], px(out, 1, 0)[2], "warmer means more red than blue")
    }
}

// MARK: Alpha tools

final class AlphaToolTests: XCTestCase {
    func testShiftGrowsAndShrinksTheCutOut() {
        let src = disc(64, radius: 20)
        let base = opaqueCount(src)
        let shrunk = opaqueCount(AlphaTools.refine(src, RefineOptions(feather: 0, shift: -2, defringe: false)))
        let grown = opaqueCount(AlphaTools.refine(src, RefineOptions(feather: 0, shift: 2, defringe: false)))
        XCTAssertEqual(Double(shrunk), Double.pi * 18 * 18, accuracy: Double.pi * 18 * 18 * 0.06)
        XCTAssertEqual(Double(grown), Double.pi * 22 * 22, accuracy: Double.pi * 22 * 22 * 0.06)
        XCTAssertLessThan(shrunk, base); XCTAssertGreaterThan(grown, base)
    }

    func testFeatherSoftensTheEdge() {
        let hard = AlphaTools.refine(disc(64, radius: 20), RefineOptions(feather: 0, defringe: false))
        let soft = AlphaTools.refine(disc(64, radius: 20), RefineOptions(feather: 2, defringe: false))
        func partial(_ i: RGBAImage) -> Int { (0..<(i.width * i.height)).filter { let a = Int(i.pixels[$0 * 4 + 3]); return a > 20 && a < 235 }.count }
        XCTAssertEqual(partial(hard), 0)
        XCTAssertGreaterThan(partial(soft), 40)
    }

    func testHardeningRemovesStrayFaintPixels() {
        var src = disc(64, radius: 20)
        src.pixels[(3 * 64 + 3) * 4 + 3] = 40            // a faint speck far from the subject
        let out = AlphaTools.refine(src, RefineOptions(feather: 0, defringe: false))
        XCTAssertEqual(px(out, 3, 3)[3], 0)
        let kept = AlphaTools.refine(src, RefineOptions(feather: 0, harden: false, defringe: false))
        XCTAssertEqual(px(kept, 3, 3)[3], 40, "without hardening it stays")
    }

    func testDefringeReplacesTheOldBackgroundColourAtTheEdge() {
        // A red disc whose outer ring picked up the green of the old background.
        let c = 32.0
        let src = image(64, 64) { x, y in
            let d = ((Double(x) + 0.5 - c) * (Double(x) + 0.5 - c) + (Double(y) + 0.5 - c) * (Double(y) + 0.5 - c)).squareRoot()
            if d <= 19 { return [255, 0, 0, 255] }
            if d <= 21 { return [0, 255, 0, 220] }
            return [0, 0, 0, 0]
        }
        let out = AlphaTools.refine(src, RefineOptions(feather: 0, shift: 0, harden: true, defringe: true))
        var checked = 0
        for i in 0..<(64 * 64) where out.pixels[i * 4 + 3] > 0 {
            checked += 1
            XCTAssertLessThan(Int(out.pixels[i * 4 + 1]), 80, "pixel \(i) is no longer green")
            XCTAssertGreaterThan(Int(out.pixels[i * 4]), 175)
        }
        XCTAssertGreaterThan(checked, 1000)
        let kept = AlphaTools.refine(src, RefineOptions(feather: 0, harden: true, defringe: false))
        XCTAssertGreaterThan(px(kept, 32 + 20, 32)[1], 200, "without defringe the green stays")
    }

    func testStickerBorderFollowsTheOutline() {
        let src = disc(40, radius: 10, colour: [200, 30, 30, 255])
        let (out, pad) = AlphaTools.border(src, thickness: 5)
        XCTAssertEqual(pad, 7)
        XCTAssertEqual(out.width, 54); XCTAssertEqual(out.height, 54)
        let c = 27
        XCTAssertEqual(px(out, c, c), [200, 30, 30, 255], "the artwork is untouched")
        let inside = px(out, c + 12, c)              // 3 pixels from the artwork's edge, inside the 5 pixel border
        XCTAssertEqual(inside[3], 255); XCTAssertEqual(Array(inside.prefix(3)), [255, 255, 255], "white border")
        XCTAssertEqual(px(out, c + 16, c)[3], 0, "and nothing beyond it")
        let edge = (0..<54).filter { let a = px(out, $0, c)[3]; return a > 10 && a < 245 }.count
        XCTAssertLessThanOrEqual(edge, 4, "a crisp, antialiased outer edge")
        XCTAssertEqual(AlphaTools.border(src, thickness: 0).padding, 0)
    }

    func testBorderColourAndSeparatePieces() {
        // Two dots far apart each get their own border, with a gap between.
        let src = image(60, 20) { x, y in
            let a = ((x - 10) * (x - 10) + (y - 10) * (y - 10)) <= 16, b = ((x - 50) * (x - 50) + (y - 10) * (y - 10)) <= 16
            return a || b ? [0, 0, 255, 255] : [0, 0, 0, 0]
        }
        let (out, pad) = AlphaTools.border(src, thickness: 3, color: RGBA(1, 1, 0))
        XCTAssertEqual(Array(px(out, 10 + pad + 5, 10 + pad).prefix(3)), [255, 255, 0])
        XCTAssertEqual(px(out, 30 + pad, 10 + pad)[3], 0, "no bridge between them")
    }

    func testDropShadow() {
        let src = image(10, 10) { _, _ in [255, 0, 0, 255] }
        let (out, pad) = AlphaTools.dropShadow(src, dx: 5, dy: 5, blur: 0, color: .black, opacity: 0.5)
        XCTAssertEqual(pad, 6)
        XCTAssertEqual(out.width, 22)
        XCTAssertEqual(px(out, pad + 2, pad + 2), [255, 0, 0, 255], "the picture stays on top")
        let s = px(out, pad + 12, pad + 12)
        XCTAssertEqual(s[3], 128, accuracy: 1); XCTAssertEqual(Array(s.prefix(3)), [0, 0, 0])
        XCTAssertEqual(px(out, pad - 1, pad - 1)[3], 0, "no shadow up and to the left")

        let (soft, softPad) = AlphaTools.dropShadow(src, dx: 0, dy: 0, blur: 3, opacity: 1)
        XCTAssertGreaterThan(softPad, 9)
        let edge = px(soft, softPad - 2, softPad + 5)
        XCTAssertGreaterThan(edge[3], 10); XCTAssertLessThan(edge[3], 200, "a soft falloff beyond the edge")
    }
}

// MARK: Halftone and distress

final class EffectTests: XCTestCase {
    private func flat(_ v: UInt8, alpha: UInt8 = 255, size: Int = 120) -> RGBAImage { image(size, size) { _, _ in [v, v, v, alpha] } }

    func testDotAreaFollowsTone() {
        let mid = meanAlpha(Halftone.apply(flat(128), HalftoneOptions(cell: 12, angle: 45)))
        XCTAssertEqual(mid, 0.5, accuracy: 0.08)
        let light = meanAlpha(Halftone.apply(flat(200), HalftoneOptions(cell: 12)))
        let dark = meanAlpha(Halftone.apply(flat(50), HalftoneOptions(cell: 12)))
        XCTAssertLessThan(light, mid); XCTAssertGreaterThan(dark, mid)
        XCTAssertGreaterThan(meanAlpha(Halftone.apply(flat(0), HalftoneOptions(cell: 12))), 0.92, "solid black fills in")
        XCTAssertEqual(meanAlpha(Halftone.apply(flat(255), HalftoneOptions(cell: 12))), 0, "white has no dots")
        XCTAssertEqual(meanAlpha(Halftone.apply(flat(0, alpha: 0), HalftoneOptions(cell: 12))), 0, "nor does transparency")
    }

    func testInvertAndGain() {
        XCTAssertGreaterThan(meanAlpha(Halftone.apply(flat(255), HalftoneOptions(cell: 12, invert: true))), 0.92)
        XCTAssertEqual(meanAlpha(Halftone.apply(flat(0), HalftoneOptions(cell: 12, invert: true))), 0)
        let normal = meanAlpha(Halftone.apply(flat(128), HalftoneOptions(cell: 12)))
        XCTAssertLessThan(meanAlpha(Halftone.apply(flat(128), HalftoneOptions(cell: 12, gain: 0.5))), normal)
        XCTAssertGreaterThan(meanAlpha(Halftone.apply(flat(128), HalftoneOptions(cell: 12, gain: 1.4))), normal)
    }

    func testDotsAreRoundAndColoured() {
        let red = image(60, 60) { _, _ in [255, 0, 0, 255] }
        let out = Halftone.apply(red, HalftoneOptions(cell: 10, angle: 0, ink: nil))
        var covered = 0
        for i in 0..<(60 * 60) where out.pixels[i * 4 + 3] > 200 {
            covered += 1
            XCTAssertGreaterThan(Int(out.pixels[i * 4]), 200); XCTAssertLessThan(Int(out.pixels[i * 4 + 1]), 50)
        }
        XCTAssertGreaterThan(covered, 300)
        let inked = Halftone.apply(red, HalftoneOptions(cell: 10, angle: 0, ink: RGBA(0, 0, 1)))
        let i = (0..<(60 * 60)).first { inked.pixels[$0 * 4 + 3] > 200 }!
        XCTAssertEqual(Int(inked.pixels[i * 4 + 2]), 255)
    }

    func testAngleChangesThePatternAndItIsRepeatable() {
        let src = flat(128, size: 60)
        let a = Halftone.apply(src, HalftoneOptions(cell: 10, angle: 0)), b = Halftone.apply(src, HalftoneOptions(cell: 10, angle: 45))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, Halftone.apply(src, HalftoneOptions(cell: 10, angle: 0)))
    }

    func testDotRadiusGrowsWithTone() {
        var last = -1.0
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            let r = Halftone.radius(forTone: t, cell: 10)
            XCTAssertGreaterThanOrEqual(r, last); last = r
        }
        XCTAssertEqual(Halftone.radius(forTone: 0.5, cell: 10) * Halftone.radius(forTone: 0.5, cell: 10) * Double.pi / 100, 0.5, accuracy: 0.01, "area is the tone")
        XCTAssertGreaterThan(Halftone.radius(forTone: 1, cell: 10), 7, "full tone covers the cell corners")
    }

    func testDistressRemovesTheAskedFractionAndOnlyAlpha() {
        let src = image(100, 100) { x, y in [UInt8(x), UInt8(y), 99, 255] }
        XCTAssertEqual(Distress.apply(src, DistressOptions(amount: 0)), src)
        let out = Distress.apply(src, DistressOptions(amount: 0.4, scale: 10, seed: 7))
        let gone = Double((0..<10000).filter { out.pixels[$0 * 4 + 3] < 128 }.count) / 10000
        XCTAssertEqual(gone, 0.4, accuracy: 0.05)
        for i in 0..<10000 { for c in 0..<3 { XCTAssertEqual(out.pixels[i * 4 + c], src.pixels[i * 4 + c]) } }
        let all = Distress.apply(src, DistressOptions(amount: 1))
        XCTAssertLessThan(meanAlpha(all), 0.05)
    }

    func testDistressIsRepeatableAndSeedsDiffer() {
        let src = image(80, 80) { _, _ in [10, 10, 10, 255] }
        let a = Distress.apply(src, DistressOptions(amount: 0.3, seed: 1)), b = Distress.apply(src, DistressOptions(amount: 0.3, seed: 1))
        let c = Distress.apply(src, DistressOptions(amount: 0.3, seed: 2))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDistressLeavesTransparencyAndScalesTheWear() {
        let src = image(80, 80) { x, _ in x < 40 ? [10, 10, 10, 255] : [0, 0, 0, 0] }
        let out = Distress.apply(src, DistressOptions(amount: 0.5))
        for y in 0..<80 { for x in 40..<80 { XCTAssertEqual(px(out, x, y)[3], 0) } }
        // Coarse wear changes more slowly than fine wear: fewer on/off flips along a row.
        let solid = image(200, 20) { _, _ in [0, 0, 0, 255] }
        func flips(_ s: Double) -> Int {
            let o = Distress.apply(solid, DistressOptions(amount: 0.5, scale: s, roughness: 1, seed: 3))
            var n = 0
            for x in 1..<200 where (o.pixels[(10 * 200 + x) * 4 + 3] > 127) != (o.pixels[(10 * 200 + x - 1) * 4 + 3] > 127) { n += 1 }
            return n
        }
        XCTAssertGreaterThan(flips(4), flips(40))
    }
}
