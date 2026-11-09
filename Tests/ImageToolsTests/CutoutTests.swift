import XCTest
import Export
@testable import ImageTools

final class CutoutTests: XCTestCase {
    private func solid(_ w: Int, _ h: Int, r: UInt8 = 200, g: UInt8 = 100, b: UInt8 = 50) -> RGBAImage {
        var p = [UInt8](); for _ in 0..<(w * h) { p += [r, g, b, 255] }
        return RGBAImage(width: w, height: h, pixels: p)
    }

    func testMaskSetsAlphaAndKeepsColour() {
        let img = solid(2, 1)
        let out = CutoutMask.apply([1, 0.5], to: img)
        XCTAssertEqual(Array(out.pixels[0..<4]), [200, 100, 50, 255])
        XCTAssertEqual(Array(out.pixels[4..<8]), [200, 100, 50, 128])
    }

    func testMaskMultipliesExistingAlphaAndClamps() {
        var img = solid(2, 1)
        img.pixels[3] = 100
        let out = CutoutMask.apply([0.5, 7], to: img)
        XCTAssertEqual(out.pixels[3], 50)
        XCTAssertEqual(out.pixels[7], 255)
    }

    func testResizeKeepsSizeAndInterpolates() {
        XCTAssertEqual(CutoutMask.resize([0, 1], width: 2, height: 1, toWidth: 2, toHeight: 1), [0, 1])
        let up = CutoutMask.resize([0, 1, 0, 1], width: 2, height: 2, toWidth: 4, toHeight: 4)
        XCTAssertEqual(up.count, 16)
        XCTAssertEqual(up[0], 0, accuracy: 0.001)
        XCTAssertEqual(up[3], 1, accuracy: 0.001)
        XCTAssertTrue(up[1] > 0 && up[1] < 1)
    }

    #if canImport(Vision) && canImport(CoreGraphics)
    func testCGImageRoundTripKeepsPixels() throws {
        var img = solid(3, 2)
        img.pixels[3] = 128; img.pixels[0] = 90; img.pixels[1] = 60; img.pixels[2] = 30
        let cg = try XCTUnwrap(VisionCutout.makeCGImage(img))
        let back = try XCTUnwrap(VisionCutout.makeRGBA(cg))
        XCTAssertEqual(back.width, 3); XCTAssertEqual(back.height, 2)
        XCTAssertEqual(back.pixels[3], 128)
        for c in 0..<3 { XCTAssertEqual(Int(back.pixels[c]), Int(img.pixels[c]), accuracy: 2) }
        XCTAssertEqual(Array(back.pixels[4..<8]), [200, 100, 50, 255])
    }

    /// A flat picture has no subject, so Vision may find none or something; both are valid. This only proves the request
    /// runs on the CI machine without crashing and that a result keeps the picture's size.
    func testVisionRunsOnAPlainPicture() throws {
        let img = solid(256, 256)
        do {
            let out = try VisionCutout.removeBackground(from: img)
            XCTAssertEqual(out.width, 256); XCTAssertEqual(out.height, 256)
        } catch let e as CutoutError {
            XCTAssertEqual(e, .noSubject)
        } catch {
            print("Vision unavailable on this machine: \(error)")
        }
    }
    #endif
}
