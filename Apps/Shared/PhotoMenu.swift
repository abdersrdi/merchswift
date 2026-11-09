import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Toolbar buttons to add a picture and to edit the selected one (cut out the background, border, shadow, effects).
struct PhotoMenu: View {
    @StateObject private var editor: PhotoEditor
    @ObservedObject var model: EditorModel
    @State private var pickedItem: PhotosPickerItem?
    @State private var showFiles = false

    init(model: EditorModel) {
        self.model = model
        _editor = StateObject(wrappedValue: PhotoEditor(model: model))
    }

    var body: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $pickedItem, matching: .images) { Label("Add a photo", systemImage: "photo.badge.plus") }
            Button { showFiles = true } label: { Label("Add a picture from Files", systemImage: "folder.badge.plus") }
            Menu {
                ForEach(PhotoEdit.allCases) { edit in
                    Button { editor.apply(edit) } label: { Label(edit.title, systemImage: edit.icon) }
                }
            } label: {
                if editor.busy { ProgressView() } else { Label("Picture tools", systemImage: "wand.and.stars.inverse") }
            }
            .disabled(editor.selectedImageLayer == nil || editor.busy)
        }
        .onChange(of: pickedItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { editor.importPicture(data) }
                else { editor.message = "This photo could not be loaded." }
                pickedItem = nil
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { editor.importPicture(data) } else { editor.message = "This file could not be read." }
        }
        .alert("Pictures", isPresented: Binding(get: { editor.message != nil }, set: { if !$0 { editor.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(editor.message ?? "") }
    }
}
