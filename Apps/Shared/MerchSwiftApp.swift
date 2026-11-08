import SwiftUI

@main
struct MerchSwiftApp: App {
    var body: some Scene {
        WindowGroup {
            ProofView()
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
    }
}
