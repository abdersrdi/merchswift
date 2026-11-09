import XCTest
import Export
@testable import ImageTools

final class UpscalerTests: XCTestCase {
    private func checker(_ w: Int, _ h: Int) -> RGBAImage {
        var p = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let v: UInt8 = (x / 2 + y / 2) % 2 == 0 ? 20 : 235
            let i = (y * w + x) * 4
            p[i] = v; p[i + 1] = v; p[i + 2] = v
        } }
        return RGBAImage(width: w, height: h, pixels: p)
    }

    func testFactorFromDPI() {
        XCTAssertEqual(Upscaler.factor(effectiveDPI: 150, targetDPI: 300), 2, accuracy: 1e-9)
        XCTAssertEqual(Upscaler.factor(effectiveDPI: 300, targetDPI: 300), 1)
        XCTAssertEqual(Upscaler.factor(effectiveDPI: 400, targetDPI: 300), 1)
        XCTAssertEqual(Upscaler.factor(effectiveDPI: 0, targetDPI: 300), 1)
    }

    func testUpscaleGrowsTheImage() {
        let out = Upscaler.upscale(checker(20, 10), factor: 2.5)
        XCTAssertEqual(out.width, 50)
        XCTAssertEqual(out.height, 25)
        XCTAssertEqual(out.pixels.count, 50 * 25 * 4)
    }

    func testNoEnlargementReturnsTheSameImage() {
        let img = checker(8, 8)
        XCTAssertEqual(Upscaler.upscale(img, factor: 1), img)
        XCTAssertEqual(Upscaler.upscale(img, factor: 0.5), img)
    }

    func testSizeIsCapped() {
        let out = Upscaler.upscale(checker(100, 50), factor: 1000, sharpen: false)
        XCTAssertEqual(max(out.width, out.height), Upscaler.maxSide)
        XCTAssertEqual(out.width, 8192)
        XCTAssertEqual(out.height, 4096)
    }

    func testOpaquePictureStaysOpaque() {
        let out = Upscaler.upscale(checker(16, 16), factor: 3)
        for i in 0..<(out.width * out.height) { XCTAssertEqual(out.pixels[i * 4 + 3], 255) }
    }

    func testEdgesOfACutOutStayClean() {
        // A red square on a transparent background: after enlarging no pixel may turn dark at the edge.
        var p = [UInt8](repeating: 0, count: 12 * 12 * 4)
        for y in 3..<9 { for x in 3..<9 { let i = (y * 12 + x) * 4; p[i] = 255; p[i + 3] = 255 } }
        let out = Upscaler.upscale(RGBAImage(width: 12, height: 12, pixels: p), factor: 2)
        for i in 0..<(out.width * out.height) where out.pixels[i * 4 + 3] > 200 {
            XCTAssertGreaterThan(Int(out.pixels[i * 4]), 200, "a solid pixel next to the edge turned dark")
        }
    }
}
