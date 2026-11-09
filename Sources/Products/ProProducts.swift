import Foundation

/// The App Store subscription products that unlock Pro. Create these two in App Store Connect, in one subscription group,
/// with exactly these ids. Both unlock the same thing; the yearly plan carries the 7-day free trial.
public enum ProProducts {
    public static let monthly = "cc.pdfswift.merchswift.pro.monthly"
    public static let yearly = "cc.pdfswift.merchswift.pro.yearly"
    public static let all = [monthly, yearly]

    /// Where the legal pages live. The App Store requires both to be linked from the purchase screen.
    public static let termsURL = "https://pdfswift.cc/merchswift-terms"
    public static let privacyURL = "https://pdfswift.cc/merchswift-privacy"

    public static func grantsPro(_ productID: String) -> Bool { all.contains(productID) }
}
