import Foundation
import Products

/// Where the app asks for a rewarded video. The iPhone and iPad build installs the AdMob version (see Apps/iOS/Ads); the
/// Mac build has none, because Google's ad SDK does not support native Mac apps, so there nothing is offered.
@MainActor
final class AdHooks: ObservableObject {
    static let shared = AdHooks()

    /// True where this build can show rewarded videos at all.
    var supportsRewarded = false
    /// True while a video is loaded and ready to play.
    @Published var rewardedAvailable = false
    /// Plays a video. The completion gets true only if the viewer watched it to the end and earned the reward.
    var showRewarded: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    /// True where the law requires an entry point for changing the consent choice again (the EEA and UK).
    @Published var privacyOptionsRequired = false
    /// Opens Google's form for changing the consent choice.
    var showPrivacyOptions: () -> Void = {}

    private init() {}
}

/// The free plan's rules, in one place.
///
/// - Free (iPhone and iPad): five exports a month. A watched video earns one more export, or removes the watermark from one
///   export, whichever the person chooses. Free exports carry a small MerchSwift mark.
/// - Pro: no limit and no mark, on every device.
/// - Mac: Pro only. The Mac is for print shops, and Google's ad SDK does not run on the Mac, so there is no free route there.
@MainActor
final class WatermarkPolicy: ObservableObject {
    static let shared = WatermarkPolicy()

    /// Set by the purchase code once Pro is bought (milestone 7). False until then. Debug builds can pass `-pro` to try Pro.
    @Published var isPro = false
    /// Videos watched to remove the watermark from one export each; kept until used.
    @Published private(set) var cleanExports: Int
    @Published private(set) var quota: ExportQuota

    private static let cleanKey = "cleanExports"
    private static let quotaKey = "exportQuota"

    private init() {
        cleanExports = UserDefaults.standard.integer(forKey: Self.cleanKey)
        let month = ExportQuota.monthKey(for: Date())
        var q = ExportQuota(month: month)
        if let data = UserDefaults.standard.data(forKey: Self.quotaKey), let saved = try? JSONDecoder().decode(ExportQuota.self, from: data) { q = saved }
        q.roll(to: month)
        quota = q
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-pro") { isPro = true }
        #endif
    }

    /// True on the Mac build, where the app needs Pro to export.
    var requiresPro: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    var canExport: Bool { requiresPro ? isPro : quota.canExport(isPro: isPro) }
    var exportsLeft: Int { quota.remaining }
    var shouldWatermark: Bool { !isPro && cleanExports == 0 }

    func earnCleanExport() {
        cleanExports += 1
        UserDefaults.standard.set(cleanExports, forKey: Self.cleanKey)
    }

    func earnExtraExport() {
        quota.grantBonus()
        saveQuota()
    }

    /// Call after an export went out: it counts against the allowance, and a clean export earned by a video is used up.
    func exportFinished(wasClean: Bool) {
        quota.roll(to: ExportQuota.monthKey(for: Date()))
        quota.record(isPro: isPro)
        saveQuota()
        if wasClean, !isPro, cleanExports > 0 {
            cleanExports -= 1
            UserDefaults.standard.set(cleanExports, forKey: Self.cleanKey)
        }
    }

    private func saveQuota() {
        if let data = try? JSONEncoder().encode(quota) { UserDefaults.standard.set(data, forKey: Self.quotaKey) }
    }
}
