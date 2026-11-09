import DesignFile
import Products
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The saved designs: open one, rename the current one, back it up or share it, import one, delete.
struct DesignsView: View {
    @ObservedObject var session: DesignSession
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                Section("This design") {
                    TextField("Name", text: $name)
                        .onSubmit { session.rename(to: name) }
                    Text("Changes are saved automatically.").font(.caption).foregroundStyle(.secondary)
                    Button { Task { await session.exportCurrent() } } label: { Label("Make a file to back up or share", systemImage: "doc.zipper") }
                        .disabled(session.busy)
                    if let url = session.exportURL {
                        ShareLink(item: url) { Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    }
                    if let s = session.status { Text(s).font(.caption).foregroundStyle(.red) }
                }
                Section("Saved designs") {
                    if session.entries.isEmpty {
                        Text("Nothing saved yet. Your design is saved as soon as you change it.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(session.entries) { entry in
                        Button {
                            Task { await session.open(entry.id); dismiss() }
                        } label: {
                            HStack(spacing: 12) {
                                Thumbnail(url: entry.thumbnailURL)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(entry.title).font(.headline)
                                        if entry.id == session.currentID { Text("open").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in offsets.map { session.entries[$0].id }.forEach(session.delete) }
                    Button { showImport = true } label: { Label("Import a design file", systemImage: "square.and.arrow.down") }
                }
                if session.busy { ProgressView() }
            }
            .navigationTitle("My designs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { session.rename(to: name); dismiss() } } }
            .onAppear { name = model.store.document.title; session.exportURL = nil; session.refresh() }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.data]) { result in
                guard case .success(let url) = result else { return }
                Task { await session.importFile(url); dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func subtitle(_ e: DesignEntry) -> String {
        let product = e.presetID.flatMap { ProductCatalog.preset(id: $0)?.name }
        let date = e.modified.formatted(date: .abbreviated, time: .shortened)
        return [product, date].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The small preview saved with a design, or a plain placeholder.
private struct Thumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let image = load() { image.resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: 48, height: 48)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func load() -> Image? {
        guard let url else { return nil }
        #if os(iOS)
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #else
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #endif
    }
}
