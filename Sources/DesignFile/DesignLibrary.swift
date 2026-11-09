import DocumentModel
import Foundation

/// One saved design in the list.
public struct DesignEntry: Identifiable, Equatable {
    /// The file's base name, unique in the library.
    public var id: String
    public var url: URL
    public var title: String
    public var modified: Date
    public var presetID: String?
    /// A small picture of the design, when one was saved.
    public var thumbnailURL: URL?
}

/// The folder the app keeps its designs in: one `.merchswift` package per design.
public struct DesignLibrary {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func url(for id: String) -> URL { root.appendingPathComponent(id).appendingPathExtension(DesignPackage.fileExtension) }

    public func newID() -> String { UUID().uuidString }

    /// Saved designs, newest first. A file that cannot be read is left out, not reported, so one bad file never hides the rest.
    public func entries() -> [DesignEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var out: [DesignEntry] = []
        for name in names where name.hasSuffix("." + DesignPackage.fileExtension) && !name.hasPrefix(".") {
            let url = root.appendingPathComponent(name)
            guard let info = try? DesignPackage.info(at: url) else { continue }
            let thumb = url.appendingPathComponent(DesignPackage.thumbnailName)
            out.append(DesignEntry(id: String(name.dropLast(DesignPackage.fileExtension.count + 1)), url: url, title: info.title,
                                   modified: info.modified, presetID: info.presetID,
                                   thumbnailURL: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    public func save(_ document: Document, assets: [String: Data], thumbnail: Data? = nil, id: String, modified: Date = Date()) throws {
        try DesignPackage.write(document, assets: assets, thumbnail: thumbnail, modified: modified, to: url(for: id))
    }

    /// The design as one file's data, for sharing or backing up.
    public func exportData(id: String) throws -> Data { try DesignPack.make(from: url(for: id)) }

    /// Adds a design from a design file's data as a new design (never replacing one) and returns its id.
    public func importData(_ data: Data) throws -> String {
        let id = newID()
        try DesignPack.extract(data, to: url(for: id))
        return id
    }

    public func load(id: String) throws -> (document: Document, assets: [String: Data]) {
        let r = try DesignPackage.read(from: url(for: id))
        return (r.document, r.assets)
    }

    public func delete(id: String) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }

    public func exists(id: String) -> Bool { FileManager.default.fileExists(atPath: url(for: id).path) }
}
