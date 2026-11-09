import Products
import StoreKit
import SwiftUI

/// Pro, bought as an App Store subscription (monthly or yearly). One purchase covers iPhone, iPad and Mac.
/// Pro is read from the App Store's own record of what this Apple ID owns, so Restore Purchases, family changes and
/// refunds all take effect without anything stored by us.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPro = false
    @Published private(set) var busy = false
    @Published private(set) var loadingFailed = false
    @Published var message: String?

    private var updates: Task<Void, Never>?

    private init() {}

    /// Call once at launch: starts listening for purchases made elsewhere (renewals, Ask to Buy, other devices).
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates { await self?.handle(result) }
        }
        Task {
            await refreshEntitlements()
            await loadProducts()
        }
    }

    func loadProducts() async {
        do {
            let found = try await Product.products(for: ProProducts.all)
            products = found.sorted { $0.price < $1.price }
            loadingFailed = products.isEmpty
        } catch {
            loadingFailed = true
        }
    }

    func purchase(_ product: Product) async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                case .unverified:
                    message = "The App Store could not confirm this purchase. You have not been charged for anything that failed; try again."
                }
            case .userCancelled:
                break
            case .pending:
                message = "The purchase is waiting for approval. Pro unlocks as soon as it is approved."
            @unknown default:
                break
            }
        } catch {
            message = "The purchase did not go through: \(error.localizedDescription)"
        }
    }

    func restore() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !isPro { message = "No Pro purchase was found for this Apple ID." }
        } catch {
            message = "Could not reach the App Store: \(error.localizedDescription)"
        }
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await refreshEntitlements()
    }

    /// Reads what the Apple ID owns right now and updates the app's plan.
    func refreshEntitlements() async {
        var entitled = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let t) = result, ProProducts.grantsPro(t.productID), t.revocationDate == nil else { continue }
            if let expires = t.expirationDate, expires < Date() { continue }
            entitled = true
        }
        isPro = entitled
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-pro") { return }      // a debug launch that forces Pro stays Pro
        #endif
        WatermarkPolicy.shared.isPro = entitled
    }
}
