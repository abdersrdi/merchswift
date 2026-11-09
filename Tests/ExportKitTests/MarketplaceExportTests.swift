#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import CutLine
import DocumentModel
import ImageIO
import Products
import XCTest
@testable import ExportKit

final class MarketplaceExportTests: XCTestCase {
    private func design() -> Document {
        var d = Document(title: "My Tee", size: Size2(300, 400), dpi: 300)
        d.layers = [Layer(name: "box", content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: 100, height: 100)), fill: RGBA(0.8, 0.1, 0.1))),
                          transform: .translation(50, 60))]
        return d
    }

    /// Width and height from the PNG header (the first chunk is always IHDR).
    private func pngSize(_ data: Data) -> (Int, Int) {
        let b = [UInt8](data.prefix(24))
        func be(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        return (be(16), be(20))
    }

    func testAmazonShirtFileHasTheExactPixelSize() throws {
        let file = try MarketplaceExport.export(design(), for: MarketplaceCatalog.amazonMerchShirt)
        XCTAssertEqual(file.pixelWidth, 4500)
        XCTAssertEqual(file.pixelHeight, 5400)
        let (w, h) = pngSize(file.data)
        XCTAssertEqual(w, 4500)
        XCTAssertEqual(h, 5400)
        XCTAssertEqual(file.name, "My-Tee-amazon-merch-shirt-4500x5400.png")
        XCTAssertLessThan(file.data.count, 25_000_000)
    }

    func testTheFileIsTransparentAroundTheArtworkAndTheArtworkIsAtTheTop() throws {
        let file = try MarketplaceExport.export(design(), for: MarketplaceCatalog.amazonMerchShirt)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(file.data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { px[(y * img.width + x) * 4 + 3] }
        XCTAssertEqual(alpha(2250, 5300), 0, "below the artwork is transparent")
        XCTAssertEqual(alpha(5, 5399), 0, "the bottom corner is transparent")
        XCTAssertEqual(alpha(2250, 100), 255, "the artwork touches the top and is centred")
        XCTAssertEqual(alpha(2250, 2000), 255, "inside the artwork")
    }

    func testEnlargingWarnsAndEmptyDesignsAreRefused() throws {
        let file = try MarketplaceExport.export(design(), for: MarketplaceCatalog.amazonMerchShirt)
        XCTAssertTrue(file.warnings.contains { $0.contains("enlarged") })
        XCTAssertThrowsError(try MarketplaceExport.export(Document(size: Size2(100, 100)), for: MarketplaceCatalog.amazonMerchShirt))
    }
}
#endif
