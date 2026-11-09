import Foundation

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

    private init() {}
}

/// Decides whether an export carries the MerchSwift watermark. Pro never does. A free export does, unless the person
/// watched a short video: each video removes the mark from exactly one export, and the earned export is kept until it is used.
@MainActor
final class WatermarkPolicy: ObservableObject {
    static let shared = WatermarkPolicy()

    /// Set by the purchase code once Pro is bought (milestone 7). False until then.
    @Published var isPro = false
    @Published private(set) var cleanExports: Int

    private static let key = "cleanExports"

    private init() { cleanExports = UserDefaults.standard.integer(forKey: Self.key) }

    var shouldWatermark: Bool { !isPro && cleanExports == 0 }

    func earnCleanExport() {
        cleanExports += 1
        UserDefaults.standard.set(cleanExports, forKey: Self.key)
    }

    /// Call after an export that went out without the mark because of a watched video.
    func usedCleanExport() {
        guard !isPro, cleanExports > 0 else { return }
        cleanExports -= 1
        UserDefaults.standard.set(cleanExports, forKey: Self.key)
    }
}
