import DesignFile
import Products
import SwiftUI

/// The saved designs: open one, rename the current one, delete.
struct DesignsView: View {
    @ObservedObject var session: DesignSession
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section("This design") {
                    TextField("Name", text: $name)
                        .onSubmit { session.rename(to: name) }
                    Text("Changes are saved automatically.").font(.caption).foregroundStyle(.secondary)
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
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.title).font(.headline)
                                    if entry.id == session.currentID { Text("open").font(.caption2).foregroundStyle(.secondary) }
                                }
                                Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in offsets.map { session.entries[$0].id }.forEach(session.delete) }
                }
                if session.busy { ProgressView("Opening…") }
            }
            .navigationTitle("My designs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { session.rename(to: name); dismiss() } } }
            .onAppear { name = model.store.document.title; session.refresh() }
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
