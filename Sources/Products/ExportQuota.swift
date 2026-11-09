import Foundation

/// How many exports the free plan allows. Five a month; watching a rewarded video earns one more that does not run out
/// at the end of the month. Pro has no limit. The counting is plain data so the app can store it and tests can check it.
public struct ExportQuota: Codable, Equatable {
    public static let freePerMonth = 5

    /// The calendar month the count belongs to, like "2026-11".
    public private(set) var month: String
    /// Exports made this month from the free allowance.
    public private(set) var used: Int
    /// Extra exports earned by watching videos. They carry over from month to month until used.
    public private(set) var bonus: Int

    public init(month: String, used: Int = 0, bonus: Int = 0) {
        self.month = month; self.used = used; self.bonus = bonus
    }

    /// A new month starts the free allowance again. Earned extras stay.
    public mutating func roll(to newMonth: String) {
        if newMonth != month { month = newMonth; used = 0 }
    }

    /// Exports left, not counting Pro.
    public var remaining: Int { max(0, Self.freePerMonth - used) + bonus }

    public func canExport(isPro: Bool) -> Bool { isPro || remaining > 0 }

    /// Counts one export. The free allowance is used first, then earned extras. Pro exports are not counted.
    public mutating func record(isPro: Bool) {
        guard !isPro else { return }
        if used < Self.freePerMonth { used += 1 } else if bonus > 0 { bonus -= 1 }
    }

    /// One more export, earned by watching a video.
    public mutating func grantBonus() { bonus += 1 }

    /// "2026-11" for a date, in the given time zone (UTC by default so every device agrees on when the month turns).
    public static func monthKey(for date: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
