import Foundation

/// AdMob IDs of MerchSwift. Debug builds (simulator, Xcode runs) use Google's official sample ad units, so nobody ever taps a
/// live ad while developing. Release builds (TestFlight and the App Store) use the real units below. The AdMob app ID itself is in
/// Info.plist (GADApplicationIdentifier, set in project.yml). These IDs are public by design: every app that shows ads contains them.
///
/// App ID:        ca-app-pub-2683853184901962~5306981116
///
/// Only the rewarded unit is used so far (a video removes the watermark from one export). The others are ready for later.
enum AdsConfig {
    #if DEBUG
    static let banner = "ca-app-pub-3940256099942544/2435281174"
    static let interstitial = "ca-app-pub-3940256099942544/4411468910"
    static let rewarded = "ca-app-pub-3940256099942544/1712485313"
    static let native = "ca-app-pub-3940256099942544/3986624511"
    #else
    static let banner = "ca-app-pub-2683853184901962/3697726834"
    static let interstitial = "ca-app-pub-2683853184901962/1642409135"
    static let rewarded = "ca-app-pub-2683853184901962/2319076881"
    static let native = "ca-app-pub-2683853184901962/6132318483"
    #endif
}
