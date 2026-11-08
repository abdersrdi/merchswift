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

                Section("Export") {
                    if let r = report, !r.canExport {
                        Toggle("Export even though there are errors", isOn: $overrideErrors)
                    }
                    Button { export() } label: {
                        if exporting { ProgressView() } else { Label("Export all files (ZIP)", systemImage: "square.and.arrow.up.on.square") }
                    }
                    .disabled(exporting || (report.map { !$0.canExport } ?? false) && !overrideErrors)
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
        model.store.perform("Fix: \(issue.title)") { doc in _ = Preflight.apply(fix, to: &doc, shaper: model.shaper) }
        runChecks()
    }

    private func fixAll() {
        model.store.perform("Fix print problems") { doc in _ = Preflight.fixAll(&doc, preset: preset, shaper: model.shaper) }
        runChecks()
    }

    private func export() {
        exporting = true
        message = nil
        exportedURL = nil
        let doc = model.store.document
        let pipeline = model.pipeline
        let options = ExportOptions(dpi: fineDetail ? 600 : nil, ignorePreflightErrors: overrideErrors)
        Task.detached(priority: .userInitiated) {
            do {
                let zip = try pipeline.exportArchive(doc, options: options)
                let name = (doc.title.isEmpty ? "design" : doc.title).replacingOccurrences(of: "/", with: "-")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
                try zip.write(to: url)
                await MainActor.run { exportedURL = url; message = "Ready: \(ByteCountFormatter.string(fromByteCount: Int64(zip.count), countStyle: .file))"; exporting = false }
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
            if let fix = issue.fix, let title = issue.fixTitle {
                Button(title, action: apply)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled({ if case .upscaleImage = fix { return true } else { return false } }())
            }
        }
        .padding(.vertical, 2)
    }
}
