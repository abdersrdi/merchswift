import AppTrackingTransparency
import GoogleMobileAds
import SwiftUI
import UIKit
import UserMessagingPlatform

/// The topmost view controller, which ads and consent forms are presented from.
@MainActor
func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
}

/// Called once at launch by the app; on the Mac the same name does nothing.
enum AdsBootstrap {
    @MainActor static func start() async { await AdsManager.shared.start() }
}

/// Everything about advertising on iPhone and iPad: consent, the SDK, and the rewarded video that removes the watermark.
///
/// Order at launch: Google's consent form (EU and UK only, where required), then Apple's tracking prompt, then the SDK starts and
/// a video loads. Nothing loads if consent is refused, and the app then simply offers no video (Pro still removes the mark).
final class AdsManager: NSObject, ObservableObject {
    static let shared = AdsManager()

    @Published private(set) var canRequestAds = false
    @Published private(set) var privacyOptionsRequired = false

    private var rewarded: GADRewardedAd?
    private var started = false
    private var earned = false
    private var finish: ((Bool) -> Void)?

    private override init() { super.init() }

    /// Screenshot and recording builds never show ads (and never ask for consent).
    private var disabledForCapture: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-store") || ProcessInfo.processInfo.arguments.contains("-noAds")
        #else
        return false
        #endif
    }

    @MainActor
    func start() async {
        guard !started, !disabledForCapture else { return }
        started = true

        let hooks = AdHooks.shared
        hooks.supportsRewarded = true
        hooks.showRewarded = { [weak self] done in self?.showRewarded(done) }

        try? await Task.sleep(nanoseconds: 1_200_000_000)    // let the first screen settle before any prompt appears
        await gatherConsent()
        privacyOptionsRequired = UMPConsentInformation.sharedInstance.privacyOptionsRequirementStatus == .required
        _ = await ATTrackingManager.requestTrackingAuthorization()
        guard UMPConsentInformation.sharedInstance.canRequestAds else { return }
        GADMobileAds.sharedInstance().start(completionHandler: nil)
        canRequestAds = true
        loadRewarded()
    }

    @MainActor
    private func gatherConsent() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let params = UMPRequestParameters()
            params.tagForUnderAgeOfConsent = false
            UMPConsentInformation.sharedInstance.requestConsentInfoUpdate(with: params) { error in
                if error != nil {
                    cont.resume()
                    return
                }
                UMPConsentForm.loadAndPresentIfRequired(from: topViewController()) { _ in cont.resume() }
            }
        }
    }

    /// Lets the person change their consent choice again (required wherever the consent form is shown).
    @MainActor
    func presentPrivacyOptions() {
        UMPConsentForm.presentPrivacyOptionsForm(from: topViewController()) { _ in }
    }

    // MARK: Rewarded video

    private func loadRewarded() {
        GADRewardedAd.load(withAdUnitID: AdsConfig.rewarded, request: GADRequest()) { [weak self] ad, _ in
            self?.rewarded = ad
            ad?.fullScreenContentDelegate = self
            Task { @MainActor in AdHooks.shared.rewardedAvailable = ad != nil }
        }
    }

    /// Plays the video. The completion gets true only if the viewer earned the reward, and false if they closed it early or
    /// no video was ready.
    @MainActor
    private func showRewarded(_ completion: @escaping (Bool) -> Void) {
        guard let ad = rewarded, let vc = topViewController() else {
            completion(false)
            return
        }
        earned = false
        finish = completion
        ad.present(fromRootViewController: vc) { [weak self] in self?.earned = true }
    }
}

extension AdsManager: GADFullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        rewarded = nil
        Task { @MainActor in AdHooks.shared.rewardedAvailable = false }
        let done = finish, wasEarned = earned
        finish = nil
        earned = false
        DispatchQueue.main.async { done?(wasEarned) }
        loadRewarded()
    }

    func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        rewarded = nil
        Task { @MainActor in AdHooks.shared.rewardedAvailable = false }
        let done = finish
        finish = nil
        DispatchQueue.main.async { done?(false) }
        loadRewarded()
    }
}
