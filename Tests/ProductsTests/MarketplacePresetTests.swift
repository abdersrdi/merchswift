import XCTest
import DocumentModel
@testable import Products

final class MarketplacePresetTests: XCTestCase {
    func testAmazonShirtSizeIsExact() {
        let p = MarketplaceCatalog.amazonMerchShirt
        XCTAssertEqual(p.pixelWidth, 4500)
        XCTAssertEqual(p.pixelHeight, 5400)
        XCTAssertEqual(p.dpi, 300)
        XCTAssertTrue(p.transparentBackground)
        XCTAssertEqual(p.maxFileMegabytes, 25)
        // 15 x 18 inches
        XCTAssertEqual(p.size.width, 381.0, accuracy: 1e-9)
        XCTAssertEqual(p.size.height, 457.2, accuracy: 1e-9)
        XCTAssertEqual(p.label, "Amazon Merch on Demand · shirt, hoodie, tank · 4500 × 5400 px")
    }

    func testPixelSizeRoundTripsThroughMillimetres() {
        for p in MarketplaceCatalog.all {
            XCTAssertEqual(Int((p.size.width * p.dpi / 25.4).rounded()), p.pixelWidth)
            XCTAssertEqual(Int((p.size.height * p.dpi / 25.4).rounded()), p.pixelHeight)
        }
    }

    func testIDsAreUniqueAndFindable() {
        let ids = MarketplaceCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for p in MarketplaceCatalog.all { XCTAssertEqual(MarketplaceCatalog.preset(id: p.id), p) }
        XCTAssertNil(MarketplaceCatalog.preset(id: "nope"))
    }

    func testHeightLimitsAShirtDesignAndItIsCentredSideways() {
        // A 300 x 400 mm shirt design is wider relative to its height than the 15 x 18 in area, so height limits it.
        let p = MarketplaceCatalog.amazonMerchShirt
        let place = p.placement(for: Rect2(x: 0, y: 0, width: 300, height: 400))
        XCTAssertEqual(place.scale, 457.2 / 400, accuracy: 1e-9)
        XCTAssertEqual(place.offsetX, (381.0 - 300 * place.scale) / 2, accuracy: 1e-9)
        XCTAssertEqual(place.offsetY, 0, accuracy: 1e-9)
    }

    func testPlacementFollowsTheContentOrigin() {
        let p = MarketplaceCatalog.amazonMerchShirt
        let place = p.placement(for: Rect2(x: 10, y: 20, width: 100, height: 100))
        XCTAssertEqual(place.scale, 3.81, accuracy: 1e-9)             // width limits
        XCTAssertEqual(place.offsetX, -38.1, accuracy: 1e-9)
        XCTAssertEqual(place.offsetY, -76.2, accuracy: 1e-9)
        // The content's top left corner lands at the top of the area; its right edge at the right edge.
        XCTAssertEqual(10 * place.scale + place.offsetX, 0, accuracy: 1e-9)
        XCTAssertEqual(20 * place.scale + place.offsetY, 0, accuracy: 1e-9)
        XCTAssertEqual(110 * place.scale + place.offsetX, 381.0, accuracy: 1e-9)
    }

    func testStickersAndMugsAreCentredVertically() {
        let mug = MarketplaceCatalog.redbubbleMug
        let place = mug.placement(for: Rect2(x: 0, y: 0, width: 200, height: 50))
        // 2700 x 1120 px at 300 DPI is 228.6 x 94.82 mm; the width limits, so the artwork is 228.6 mm wide, 57.15 mm tall.
        XCTAssertEqual(place.scale, mug.size.width / 200, accuracy: 1e-9)
        XCTAssertEqual(place.offsetY, (mug.size.height - 50 * place.scale) / 2, accuracy: 1e-9)
        XCTAssertGreaterThan(place.offsetY, 0)
    }

    func testPhoneGripAndTeepublicSizes() {
        XCTAssertEqual(MarketplaceCatalog.amazonPopSocket.pixelWidth, 485)
        XCTAssertEqual(MarketplaceCatalog.amazonPopSocket.pixelHeight, 485)
        XCTAssertEqual(MarketplaceCatalog.teepublicLarge.pixelWidth, 5000)
        XCTAssertEqual(MarketplaceCatalog.teepublicLarge.pixelHeight, 5000)
        XCTAssertEqual(MarketplaceCatalog.teepublicSmall.pixelWidth, 1500)
        XCTAssertEqual(MarketplaceCatalog.teepublicSmall.pixelHeight, 1995)
        // 485 px at 300 DPI is not a whole number of millimetres; the export still lands on exactly 485 px.
        let p = MarketplaceCatalog.amazonPopSocket
        XCTAssertEqual(Int((p.size.width * p.dpi / 25.4).rounded()), 485)
    }

    func testCustomSizeIsUsable() {
        let c = MarketplacePreset.custom(pixelWidth: 3000, pixelHeight: 2000)
        XCTAssertEqual(c.pixelWidth, 3000)
        XCTAssertEqual(c.size.width, 254.0, accuracy: 1e-9)
        XCTAssertEqual(MarketplacePreset.custom(pixelWidth: 0, pixelHeight: -5).pixelWidth, 1)
    }

    func testEveryPresetHasANoteAndASaneSize() {
        for p in MarketplaceCatalog.all {
            XCTAssertFalse(p.note.isEmpty, p.id)
            XCTAssertTrue((100...13500).contains(p.pixelWidth) && (100...13500).contains(p.pixelHeight), p.id)
        }
    }

    func testEmptyContentIsLeftAlone() {
        let place = MarketplaceCatalog.amazonMerchShirt.placement(for: Rect2(x: 0, y: 0, width: 0, height: 0))
        XCTAssertEqual(place, MarketplacePlacement(scale: 1, offsetX: 0, offsetY: 0))
    }
}
