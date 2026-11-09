import DesignFile
import DocumentModel
import Editor
import Export
import ExportKit
import Foundation
import ImageIO
import ImageTools
import Products

/// Keeps the open design saved. Changes are written a moment after the last edit, in the background, so there is no Save
/// button to forget. Each design is a `.merchswift` folder in the app's Documents/Designs folder.
@MainActor
final class DesignSession: ObservableObject {
    @Published private(set) var entries: [DesignEntry] = []
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    /// The file made by `exportCurrent`, ready to share.
    @Published var exportURL: URL?

    private(set) var currentID: String
    private let library: DesignLibrary
    private let model: EditorModel
    private let assets = AssetStore.shared

    private var token: UUID?
    private var saveTask: Task<Void, Never>?
    private var saving = false
    /// The store revision that is on disk. A newer revision means there are unsaved edits.
    private var savedRevision: Int
    /// Pictures already inside the current design's file, so they are not encoded again.
    private var onDisk: Set<String> = []

    private static let lastKey = "currentDesignID"

    init(model: EditorModel) {
        self.model = model
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Designs", isDirectory: true)
        library = DesignLibrary(root: root)
        let last = UserDefaults.standard.string(forKey: Self.lastKey)
        currentID = last ?? library.newID()
        savedRevision = model.store.revision
        token = model.store.observe { [weak self] in DispatchQueue.main.async { self?.documentChanged() } }
        refresh()
        if let last, library.exists(id: last) { Task { await load(id: last) } }
    }

    func refresh() { entries = library.entries() }

    // MARK: Saving

    private func documentChanged() {
        guard model.store.revision != savedRevision else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Writes the design now if it has unsaved edits.
    func saveNow() async {
        while saving { try? await Task.sleep(nanoseconds: 50_000_000) }
        let revision = model.store.revision
        guard revision != savedRevision else { return }
        saving = true
        defer { saving = false }

        let doc = model.store.document
        let id = currentID
        let ids = DesignPackage.assetIDs(in: doc)
        var fresh: [String: RGBAImage] = [:]
        for a in ids where !onDisk.contains(a) { if let px = assets.pixels(for: a) { fresh[a] = px } }
        let library = library
        let provider = assets
        do {
            try await Task.detached(priority: .utility) {
                var png: [String: Data] = [:]
                for (k, v) in fresh { png[k] = PNGEncoder.encode(v) }
                // A small preview for the list: the whole design, about 256 pixels on its longest side.
                let longest = max(doc.size.width, doc.size.height, 1)
                let thumbnail = try? PNGExporter.export(doc, assets: provider, dpi: 256 / longest * 25.4, dither: false)
                try library.save(doc, assets: png, thumbnail: thumbnail, id: id)
            }.value
            onDisk = onDisk.intersection(ids).union(fresh.keys)
            savedRevision = revision
            UserDefaults.standard.set(id, forKey: Self.lastKey)
            status = nil
            refresh()
        } catch {
            status = "Could not save: \(error)"
        }
        // Edits that arrived while the file was being written.
        if model.store.revision != savedRevision { documentChanged() }
    }

    // MARK: Opening, creating, deleting

    func open(_ id: String) async {
        guard id != currentID else { return }
        saveTask?.cancel()
        await saveNow()
        await load(id: id)
    }

    func newDesign(for preset: ProductPreset) async {
        saveTask?.cancel()
        await saveNow()
        currentID = library.newID()
        onDisk = []
        model.newDocument(for: preset)
        savedRevision = model.store.revision           // an untouched new design is not saved until it is edited
        assets.replaceAll(with: [:])
        UserDefaults.standard.set(currentID, forKey: Self.lastKey)
    }

    func delete(_ id: String) {
        do {
            try library.delete(id: id)
            if id == currentID {
                // The design stays on screen but is no longer stored; the next edit saves it as a new design.
                currentID = library.newID()
                onDisk = []
                savedRevision = model.store.revision
            }
            refresh()
        } catch {
            status = "Could not delete: \(error)"
        }
    }

    /// The current design as one file to share or keep as a backup. Saves first so the file is up to date.
    func exportCurrent() async {
        saveTask?.cancel()
        await saveNow()
        let id = currentID
        guard library.exists(id: id) else { status = "Nothing to export yet. Change the design first, then try again."; return }
        let library = library
        let name = Self.fileSafe(model.store.document.title)
        busy = true
        defer { busy = false }
        do {
            exportURL = try await Task.detached(priority: .userInitiated) {
                let data = try library.exportData(id: id)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(DesignPack.fileExtension)")
                try data.write(to: url)
                return url
            }.value
            status = nil
        } catch {
            status = "Could not make the file: \(error)"
        }
    }

    /// Adds a design from a design file as a new design and opens it.
    func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        busy = true
        let library = library
        do {
            let id = try await Task.detached(priority: .userInitiated) { try library.importData(try Data(contentsOf: url)) }.value
            refresh()
            busy = false
            await open(id)
        } catch {
            busy = false
            status = "\(error)"
        }
    }

    private static func fileSafe(_ title: String) -> String {
        let cleaned = title.map { "/\\:*?\"<>|".contains($0) ? "-" : $0 }
        let s = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "design" : s
    }

    func rename(to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != model.store.document.title else { return }
        model.store.perform("Rename design") { $0.title = t }
    }

    private func load(id: String) async {
        busy = true
        status = nil
        defer { busy = false }
        let library = library
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> (Document, [String: RGBAImage]) in
                let (doc, files) = try library.load(id: id)
                var pixels: [String: RGBAImage] = [:]
                for (key, data) in files {
                    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                          let rgba = VisionCutout.makeRGBA(cg) else { continue }
                    pixels[key] = rgba
                }
                return (doc, pixels)
            }.value
            assets.replaceAll(with: result.1)
            onDisk = Set(result.1.keys)
            currentID = id
            model.tools.select([])
            model.store.reset(to: result.0)
            savedRevision = model.store.revision
            UserDefaults.standard.set(id, forKey: Self.lastKey)
        } catch {
            status = "\(error)"
        }
    }
}
