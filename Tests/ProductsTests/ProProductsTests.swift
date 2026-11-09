import XCTest
@testable import Products

final class ProProductsTests: XCTestCase {
    func testOnlyOurSubscriptionsGrantPro() {
        XCTAssertTrue(ProProducts.grantsPro(ProProducts.monthly))
        XCTAssertTrue(ProProducts.grantsPro(ProProducts.yearly))
        XCTAssertFalse(ProProducts.grantsPro("cc.pdfswift.merchswift.credits.small"))
        XCTAssertFalse(ProProducts.grantsPro(""))
    }

    func testIdsAreDistinctAndLegalLinksAreHTTPS() {
        XCTAssertEqual(Set(ProProducts.all).count, ProProducts.all.count)
        XCTAssertTrue(ProProducts.termsURL.hasPrefix("https://"))
        XCTAssertTrue(ProProducts.privacyURL.hasPrefix("https://"))
        XCTAssertNotNil(URL(string: ProProducts.termsURL))
        XCTAssertNotNil(URL(string: ProProducts.privacyURL))
    }
}
