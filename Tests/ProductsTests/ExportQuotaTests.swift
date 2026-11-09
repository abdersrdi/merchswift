import XCTest
@testable import Products

final class ExportQuotaTests: XCTestCase {
    func testFiveFreeExportsThenNone() {
        var q = ExportQuota(month: "2026-11")
        XCTAssertEqual(q.remaining, 5)
        for i in 1...5 {
            XCTAssertTrue(q.canExport(isPro: false), "export \(i)")
            q.record(isPro: false)
        }
        XCTAssertEqual(q.remaining, 0)
        XCTAssertFalse(q.canExport(isPro: false))
        XCTAssertEqual(q.used, 5)
    }

    func testAWatchedVideoEarnsOneMoreAndItIsUsedAfterTheFreeOnes() {
        var q = ExportQuota(month: "2026-11", used: 5)
        XCTAssertFalse(q.canExport(isPro: false))
        q.grantBonus()
        XCTAssertEqual(q.remaining, 1)
        XCTAssertTrue(q.canExport(isPro: false))
        q.record(isPro: false)
        XCTAssertEqual(q.remaining, 0)
        XCTAssertEqual(q.bonus, 0)
        XCTAssertEqual(q.used, 5, "the free count stays full; the extra was spent")
        XCTAssertFalse(q.canExport(isPro: false))
    }

    func testFreeExportsAreSpentBeforeEarnedOnes() {
        var q = ExportQuota(month: "2026-11", bonus: 2)
        q.record(isPro: false)
        XCTAssertEqual(q.used, 1); XCTAssertEqual(q.bonus, 2)
        XCTAssertEqual(q.remaining, 6)
    }

    func testProIsUnlimitedAndUncounted() {
        var q = ExportQuota(month: "2026-11", used: 5)
        XCTAssertTrue(q.canExport(isPro: true))
        q.record(isPro: true)
        XCTAssertEqual(q, ExportQuota(month: "2026-11", used: 5))
    }

    func testANewMonthRefillsTheFreeAllowanceButKeepsEarnedExports() {
        var q = ExportQuota(month: "2026-11", used: 5, bonus: 3)
        q.roll(to: "2026-11")
        XCTAssertEqual(q.used, 5, "same month changes nothing")
        q.roll(to: "2026-12")
        XCTAssertEqual(q.month, "2026-12")
        XCTAssertEqual(q.used, 0)
        XCTAssertEqual(q.bonus, 3)
        XCTAssertEqual(q.remaining, 8)
    }

    func testMonthKeyUsesUTC() {
        let end = Date(timeIntervalSince1970: 1_793_491_199)         // 2026-10-31 23:59:59 UTC
        let start = Date(timeIntervalSince1970: 1_793_491_200)       // 2026-11-01 00:00:00 UTC
        XCTAssertEqual(ExportQuota.monthKey(for: end), "2026-10")
        XCTAssertEqual(ExportQuota.monthKey(for: start), "2026-11")
        XCTAssertEqual(ExportQuota.monthKey(for: Date(timeIntervalSince1970: 0)), "1970-01")
    }

    func testStoresAsJSON() throws {
        let q = ExportQuota(month: "2026-11", used: 3, bonus: 1)
        XCTAssertEqual(try JSONDecoder().decode(ExportQuota.self, from: try JSONEncoder().encode(q)), q)
    }

    func testNeverNegative() {
        var q = ExportQuota(month: "2026-11", used: 5)
        q.record(isPro: false)                                      // nothing left: nothing changes
        XCTAssertEqual(q.remaining, 0)
        XCTAssertEqual(q.bonus, 0)
    }
}
