import Foundation

/// The Mac build shows no ads: Google's ad SDK does not support native Mac apps. Free Mac exports keep the watermark until Pro.
enum AdsBootstrap {
    @MainActor static func start() async {}
}
