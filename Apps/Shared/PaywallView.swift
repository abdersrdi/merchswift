import Products
import StoreKit
import SwiftUI

/// Where Pro is offered. Shows the real price from the App Store, the free trial when the plan has one, how renewal works,
/// and links to the terms and privacy policy, as the App Store requires.
struct PaywallView: View {
    @ObservedObject private var store = ProStore.shared
    @ObservedObject private var policy = WatermarkPolicy.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if policy.isPro {
                    Section {
                        Label("You have Pro. Thank you!", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                } else {
                    Section {
                        benefit("infinity", "Unlimited exports, no monthly limit")
                        benefit("drop.degreesign.slash", "No watermark on your files")
                        benefit("nosign", "No ads")
                        benefit("desktopcomputer", "Works on iPhone, iPad and Mac with one purchase")
                    } header: { Text("MerchSwift Pro") }

                    Section("Choose a plan") {
                        if store.products.isEmpty {
                            if store.loadingFailed {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("The plans could not be loaded. Check your connection and try again.").font(.callout)
                                    Button("Try again") { Task { await store.loadProducts() } }
                                }
                            } else { ProgressView() }
                        }
                        ForEach(store.products, id: \.id) { product in
                            Button { Task { await store.purchase(product) } } label: { planRow(product) }
                                .disabled(store.busy)
                        }
                    }
                }

                Section {
                    Button("Restore purchases") { Task { await store.restore() } }.disabled(store.busy)
                    if let m = store.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                    if store.busy { ProgressView() }
                }

                Section {
                    Text("Payment is charged to your Apple ID when you confirm. The subscription renews automatically at the price shown unless you cancel at least 24 hours before the end of the current period. Manage or cancel it any time in your Apple ID settings. Any free trial turns into a paid subscription at the end unless you cancel before.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let terms = URL(string: ProProducts.termsURL) { Link("Terms of Use", destination: terms) }
                    if let privacy = URL(string: ProProducts.privacyURL) { Link("Privacy Policy", destination: privacy) }
                }
            }
            .navigationTitle("Go Pro")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if store.products.isEmpty { await store.loadProducts() } }
            .onChange(of: policy.isPro) { pro in if pro { dismiss() } }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
    }

    private func planRow(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(product.displayName).font(.headline)
                Spacer()
                Text("\(product.displayPrice)\(periodSuffix(product))").font(.headline)
            }
            if let trial = trialText(product) { Text(trial).font(.caption).foregroundStyle(.green) }
        }
    }

    private func periodSuffix(_ product: Product) -> String {
        switch product.subscription?.subscriptionPeriod.unit {
        case .month: return " / month"
        case .year: return " / year"
        case .week: return " / week"
        case .day: return " / day"
        default: return ""
        }
    }

    private func trialText(_ product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        let unit: String
        switch offer.period.unit {
        case .day: unit = n == 1 ? "day" : "days"
        case .week: unit = n == 1 ? "week" : "weeks"
        case .month: unit = n == 1 ? "month" : "months"
        case .year: unit = n == 1 ? "year" : "years"
        @unknown default: unit = "days"
        }
        return "\(n)-\(unit.dropLast(unit.hasSuffix("s") ? 1 : 0)) free trial, then \(product.displayPrice)\(periodSuffix(product))"
    }
}
