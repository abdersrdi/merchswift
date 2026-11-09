import Products
import SwiftUI
import Typography

/// About MerchSwift: the open-source and third-party software the app contains, with the licence texts their authors require
/// to be shown, and links to the terms and privacy policy.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private let fontLicenses = FontLibrary.bundledLicenses()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("MerchSwift version \(version)").font(.callout)
                    if let terms = URL(string: ProProducts.termsURL) { Link("Terms of Use", destination: terms) }
                    if let privacy = URL(string: ProProducts.privacyURL) { Link("Privacy Policy", destination: privacy) }
                }

                Section("Software in this app") {
                    NavigationLink("PDFio") {
                        NoticeText(title: "PDFio", parts: [
                            "PDFio 1.5.4, a PDF reading and writing library by Michael R Sweet, used to make PDF/X files. Source: https://github.com/michaelrsweet/pdfio. Licensed under the Apache License 2.0, with the exception described in its notice. One small change was made: the end-of-file marker is written correctly.",
                            Self.text("PDFio-NOTICE"),
                            Self.text("PDFio-LICENSE"),
                        ])
                    }
                    NavigationLink("Little CMS") {
                        NoticeText(title: "Little CMS", parts: [
                            "The colour profile embedded in exported files is generated with Little CMS, licensed under the MIT licence.",
                            Self.text("LittleCMS-MIT"),
                        ])
                    }
                    NavigationLink("Google Mobile Ads and User Messaging Platform") {
                        NoticeText(title: "Google software", parts: [
                            "The iPhone and iPad apps include the Google Mobile Ads SDK and the Google User Messaging Platform SDK, © Google LLC, used under Google's terms. They show the optional rewarded video and the consent form. See the Privacy Policy for what they may collect.",
                        ])
                    }
                    Text("zlib compression is provided by the operating system.").font(.caption).foregroundStyle(.secondary)
                }

                Section("Fonts") {
                    Text("These fonts come with the app and are licensed under the SIL Open Font License 1.1. They are not sold on their own.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(fontLicenses) { license in
                        NavigationLink(license.family) { NoticeText(title: license.family, parts: [license.text]) }
                    }
                }
            }
            .navigationTitle("About")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? ""
        let b = info?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    /// A notice file from the app's resources.
    private static func text(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"), let s = try? String(contentsOf: url, encoding: .utf8) else {
            return "(The licence text for \(name) could not be loaded.)"
        }
        return s
    }
}

private struct NoticeText: View {
    let title: String
    let parts: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Text(part).font(.caption).textSelection(.enabled)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
