import DocumentModel
import Editor
import ExportKit
import Preflight
import Products
import SwiftUI

/// The print checks for the open design, with one-tap fixes, and the export button.
struct PrintPanel: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var report: PreflightReport?
    @State private var checking = false
    @State private var exporting = false
    @State private var fineDetail = false
    @State private var overrideErrors = false
    @State private var exportedURL: URL?
    @State private var message: String?
    @State private var watchingVideo = false
    @StateObject private var photos: PhotoEditor
    @State private var marketID = MarketplaceCatalog.amazonMerchShirt.id
    @State private var customWidth = "4500"
    @State private var customHeight = "5400"
    @State private var marketURL: URL?
    @State private var showPaywall = false
    @ObservedObject private var policy = WatermarkPolicy.shared
    @ObservedObject private var ads = AdHooks.shared

    init(model: EditorModel) {
        self.model = model
        _photos = StateObject(wrappedValue: PhotoEditor(model: model))
    }

    private var preset: ProductPreset? { ProductCatalog.preset(for: model.store.document) }

    var body: some View {
        NavigationStack {
            List {
                Section("Product") {
                    if let p = preset {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name).font(.headline)
                            Text("Trim \(fmt(p.trim.width)) x \(fmt(p.trim.height)) mm, bleed \(fmt(p.bleed)) mm, safe area \(fmt(p.safeInset)) mm, \(Int(model.store.document.dpi)) DPI")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(p.note).font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("This design is not tied to a product, so only general checks run.").font(.callout)
                    }
                    Toggle("600 DPI (fine detail)", isOn: $fineDetail)
                }

                Section("Print checks") {
                    if checking { ProgressView("Checking…") }
                    if photos.busy { ProgressView("Enlarging the picture…") }
                    if let m = photos.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                    else if let r = report {
                        if r.issues.isEmpty {
                            Label("No problems found", systemImage: "checkmark.seal").foregroundStyle(.green)
                        }
                        ForEach(r.issues) { issue in IssueRow(issue: issue, apply: { apply(issue) }) }
                    }
                    Button { runChecks() } label: { Label("Check again", systemImage: "arrow.clockwise") }
                    if let r = report, r.issues.contains(where: { $0.fix != nil }) {
                        Button { fixAll() } label: { Label("Fix everything that can be fixed", systemImage: "wand.and.stars") }
                    }
                }

                Section("Watermark") {
                    if policy.isPro {
                        Label("Pro: exports are always clean", systemImage: "checkmark.seal").foregroundStyle(.green)
                    } else if policy.cleanExports > 0 {
                        Label("Your next export has no watermark", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Text("Free exports carry a small MerchSwift mark in the corner.").font(.callout)
                        if ads.supportsRewarded {
                            Button { watchVideo() } label: {
                                if watchingVideo { ProgressView() }
                                else { Label(ads.rewardedAvailable ? "Watch a short video to remove it" : "Video loading…", systemImage: "play.rectangle") }
                            }
                            .disabled(!ads.rewardedAvailable || watchingVideo)
                            Text("One video removes the mark from one export.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button { showPaywall = true } label: { Label("Go Pro to remove it", systemImage: "star") }
                        }
                    }
                }

                Section("Upload to a selling site") {
                    Picker("Site and product", selection: $marketID) {
                        ForEach(MarketplaceCatalog.all) { Text($0.name).tag($0.id) }
                        Text("Custom size").tag("custom")
                    }
                    if marketID == "custom" {
                        HStack {
                            TextField("Width px", text: $customWidth)
                            Text("×")
                            TextField("Height px", text: $customHeight)
                        }
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    }
                    if let t = marketTarget {
                        Text("\(t.pixelWidth) × \(t.pixelHeight) px, \(Int(t.dpi)) DPI, PNG\(t.transparentBackground ? ", transparent background" : "")\(t.maxFileMegabytes.map { ", up to \(Int($0)) MB" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(t.note).font(.caption2).foregroundStyle(.secondary)
                    }
                    Button { exportMarketplace() } label: {
                        if exporting { ProgressView() } else { Label("Export PNG for this site", systemImage: "square.and.arrow.up") }
                    }
                    .disabled(exporting || marketTarget == nil || !policy.canExport)
                    if let url = marketURL {
                        ShareLink(item: url) { Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    }
                }

                Section("Export") {
                    if let r = report, !r.canExport {
                        Toggle("Export even though there are errors", isOn: $overrideErrors)
                    }
                    Button { export() } label: {
                        if exporting { ProgressView() } else { Label("Export all files (ZIP)", systemImage: "square.and.arrow.up.on.square") }
                    }
                    .disabled(exporting || !policy.canExport || (report.map { !$0.canExport } ?? false) && !overrideErrors)
                    allowanceRows
                    if let url = exportedURL {
                        ShareLink(item: url) { Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    }
                    if let m = message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Print checks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: runChecks)
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private func runChecks() {
        checking = true
        let doc = model.store.document
        let pipeline = model.pipeline
        Task.detached(priority: .userInitiated) {
            let r = pipeline.preflight(doc)
            await MainActor.run { report = r; checking = false }
        }
    }

    private func apply(_ issue: PreflightIssue) {
        guard let fix = issue.fix else { return }
        if case .upscaleImage(let layer, let dpi) = fix {
            photos.upscale(layer: layer, targetDPI: dpi) { runChecks() }
            return
        }
        model.store.perform("Fix: \(issue.title)") { doc in _ = Preflight.apply(fix, to: &doc, shaper: model.shaper) }
        runChecks()
    }

    private func fixAll() {
        model.store.perform("Fix print problems") { doc in _ = Preflight.fixAll(&doc, preset: preset, shaper: model.shaper) }
        runChecks()
    }

    private func watchVideo(forExtraExport: Bool = false) {
        watchingVideo = true
        ads.showRewarded { earned in
            watchingVideo = false
            guard earned else { return }
            if forExtraExport { policy.earnExtraExport() } else { policy.earnCleanExport() }
        }
    }

    /// How many free exports are left, and what to do when there are none.
    @ViewBuilder private var allowanceRows: some View {
        if policy.requiresPro && !policy.isPro {
            Label("Exporting on the Mac needs Pro.", systemImage: "lock")
                .font(.footnote).foregroundStyle(.secondary)
            Button { showPaywall = true } label: { Label("Get Pro", systemImage: "star") }
        } else if !policy.isPro {
            Text(policy.exportsLeft == 1 ? "1 export left" : "\(policy.exportsLeft) exports left (5 free each month)")
                .font(.footnote).foregroundStyle(.secondary)
            if policy.exportsLeft == 0 {
                if ads.supportsRewarded {
                    Button { watchVideo(forExtraExport: true) } label: {
                        Label(ads.rewardedAvailable ? "Watch a short video for one more export" : "Video loading…", systemImage: "play.rectangle")
                    }
                    .disabled(!ads.rewardedAvailable || watchingVideo)
                } else {
                    Button { showPaywall = true } label: { Label("Go Pro for unlimited exports", systemImage: "star") }
                }
            }
        }
    }

    /// The chosen site size, or the typed one. Nil when the typed numbers are not usable.
    private var marketTarget: MarketplacePreset? {
        if marketID == "custom" {
            guard let w = Int(customWidth), let h = Int(customHeight), (100...13500).contains(w), (100...13500).contains(h) else { return nil }
            return .custom(pixelWidth: w, pixelHeight: h)
        }
        return MarketplaceCatalog.preset(id: marketID)
    }

    /// Makes the PNG at the exact pixel size a selling site asks for. Counts as one export and follows the same free-plan
    /// rules as the full export (a free export carries the mark unless a watched video earned a clean one).
    private func exportMarketplace() {
        guard let target = marketTarget else { return }
        exporting = true
        message = nil
        marketURL = nil
        let doc = model.store.document
        let marked = policy.shouldWatermark
        let mark: Layer? = marked ? Watermark.layer(for: Document(size: target.size, dpi: target.dpi), shaper: model.shaper) : nil
        let usedVideo = !policy.isPro && policy.cleanExports > 0
        Task.detached(priority: .userInitiated) {
            do {
                let file = try MarketplaceExport.export(doc, for: target, assets: AssetStore.shared, watermark: mark.map { m in { _ in m } })
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
                try file.data.write(to: url)
                await MainActor.run {
                    policy.exportFinished(wasClean: usedVideo)
                    marketURL = url
                    let size = ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)
                    message = (["Ready: \(file.pixelWidth) × \(file.pixelHeight) px, \(size)"] + file.warnings).joined(separator: "\n")
                    exporting = false
                }
            } catch {
                await MainActor.run { message = "\(error)"; exporting = false }
            }
        }
    }

    private func export() {
        exporting = true
        message = nil
        exportedURL = nil
        let doc = model.store.document
        let pipeline = model.pipeline
        // A free export carries the mark unless a watched video earned a clean one.
        let marked = policy.shouldWatermark
        let mark: Layer? = marked ? Watermark.layer(for: doc, shaper: model.shaper) : nil
        let usedVideo = !policy.isPro && policy.cleanExports > 0
        let options = ExportOptions(dpi: fineDetail ? 600 : nil, ignorePreflightErrors: overrideErrors, watermark: mark)
        Task.detached(priority: .userInitiated) {
            do {
                let zip = try pipeline.exportArchive(doc, options: options)
                let name = (doc.title.isEmpty ? "design" : doc.title).replacingOccurrences(of: "/", with: "-")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
                try zip.write(to: url)
                await MainActor.run {
                    policy.exportFinished(wasClean: usedVideo)
                    exportedURL = url
                    message = "Ready: \(ByteCountFormatter.string(fromByteCount: Int64(zip.count), countStyle: .file))"
                    exporting = false
                }
            } catch {
                await MainActor.run { message = "\(error)"; exporting = false }
            }
        }
    }
}

private struct IssueRow: View {
    let issue: PreflightIssue
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                Text(issue.title).font(.subheadline.weight(.semibold))
            }
            Text(issue.detail).font(.caption).foregroundStyle(.secondary)
            if issue.fix != nil, let title = issue.fixTitle {
                Button(title, action: apply)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
