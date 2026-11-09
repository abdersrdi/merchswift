import DocumentModel
import Foundation

public enum DesignFileError: Error, Equatable, CustomStringConvertible {
    /// The folder has no design description, so it is not one of our designs.
    case notADesign
    /// The design was saved by a newer version of the app.
    case tooNew(version: Int)
    /// The description could not be read.
    case corrupt(String)

    public var description: String {
        switch self {
        case .notADesign: return "This is not a MerchSwift design."
        case .tooNew(let v): return "This design was saved by a newer version of MerchSwift (file format \(v)). Update the app to open it."
        case .corrupt(let why): return "This design file is damaged and could not be read (\(why))."
        }
    }
}

/// What the top of a design file says, so a list of designs can be shown without reading every layer.
public struct DesignFileInfo: Codable, Equatable {
    public var format: Int
    public var title: String
    public var modified: Date
    public var presetID: String?
}

/// A saved design: a folder named `Something.merchswift` holding `design.json` (the whole design, fully editable) and an
/// `assets` folder with every picture the design uses, at the resolution it has, as PNG files. Nothing is flattened.
public enum DesignPackage {
    public static let formatVersion = 1
    public static let fileExtension = "merchswift"
    static let descriptionName = "design.json"
    static let assetsFolder = "assets"
    public static let thumbnailName = "thumbnail.png"

    private struct Envelope: Codable {
        var format: Int
        var title: String
        var modified: Date
        var presetID: String?
        var document: Document
    }

    /// Every picture id a design refers to, once each, in a stable order.
    public static func assetIDs(in document: Document) -> [String] {
        var ids = Set<String>()
        func walk(_ layers: [Layer]) {
            for l in layers {
                switch l.content {
                case .image(let i): ids.insert(i.assetID)
                case .group(let kids): walk(kids)
                default: break
                }
            }
        }
        walk(document.layers)
        return ids.sorted()
    }

    /// Picture ids can be any text, so file names are made from them with every unusual character escaped.
    static func fileName(forAsset id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        return (id.addingPercentEncoding(withAllowedCharacters: allowed) ?? "asset") + ".png"
    }

    static func assetID(fromFileName name: String) -> String? {
        guard name.hasSuffix(".png") else { return nil }
        return String(name.dropLast(4)).removingPercentEncoding
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Writes the design. The new copy is built next to the old one and swapped in at the end, so a crash or a full disk
    /// in the middle never leaves a half-written design. `assets` holds PNG data by picture id; only pictures the design
    /// uses are written. A used picture that is not in `assets` is carried over from the earlier save, if there was one.
    public static func write(_ document: Document, assets: [String: Data], thumbnail: Data? = nil, modified: Date = Date(), to url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".\(url.lastPathComponent).saving-\(UUID().uuidString)")
        try fm.createDirectory(at: temp.appendingPathComponent(assetsFolder), withIntermediateDirectories: true)
        do {
            let envelope = Envelope(format: formatVersion, title: document.title, modified: modified, presetID: document.presetID, document: document)
            try makeEncoder().encode(envelope).write(to: temp.appendingPathComponent(descriptionName))
            for id in assetIDs(in: document) {
                let name = fileName(forAsset: id)
                let target = temp.appendingPathComponent(assetsFolder).appendingPathComponent(name)
                if let data = assets[id] {
                    try data.write(to: target)
                } else {
                    // Not given again: keep the file from the earlier save, so a picture is only encoded once.
                    let earlier = url.appendingPathComponent(assetsFolder).appendingPathComponent(name)
                    if fm.fileExists(atPath: earlier.path) { try fm.copyItem(at: earlier, to: target) }
                }
            }
            if let thumbnail {
                try thumbnail.write(to: temp.appendingPathComponent(thumbnailName))
            } else if fm.fileExists(atPath: url.appendingPathComponent(thumbnailName).path) {
                try fm.copyItem(at: url.appendingPathComponent(thumbnailName), to: temp.appendingPathComponent(thumbnailName))
            }
            if fm.fileExists(atPath: url.path) {
                let old = parent.appendingPathComponent(".\(url.lastPathComponent).old-\(UUID().uuidString)")
                try fm.moveItem(at: url, to: old)
                do { try fm.moveItem(at: temp, to: url) } catch {
                    try? fm.moveItem(at: old, to: url)          // put the old one back
                    throw error
                }
                try? fm.removeItem(at: old)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Reads only the top of the design.
    public static func info(at url: URL) throws -> DesignFileInfo {
        let data: Data
        do { data = try Data(contentsOf: url.appendingPathComponent(descriptionName)) } catch { throw DesignFileError.notADesign }
        do {
            let info = try makeDecoder().decode(DesignFileInfo.self, from: data)
            if info.format > formatVersion { throw DesignFileError.tooNew(version: info.format) }
            return info
        } catch let e as DesignFileError {
            throw e
        } catch {
            throw DesignFileError.corrupt("\(error)")
        }
    }

    /// Reads the design and its pictures. A picture file that is missing is simply absent from the result, so the design
    /// still opens and the layer shows as missing.
    public static func read(from url: URL) throws -> (document: Document, assets: [String: Data], modified: Date) {
        _ = try info(at: url)
        let fm = FileManager.default
        let envelope: Envelope
        do {
            envelope = try makeDecoder().decode(Envelope.self, from: Data(contentsOf: url.appendingPathComponent(descriptionName)))
        } catch {
            throw DesignFileError.corrupt("\(error)")
        }
        var assets: [String: Data] = [:]
        let folder = url.appendingPathComponent(assetsFolder)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard let id = assetID(fromFileName: name), let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { continue }
            assets[id] = data
        }
        return (envelope.document, assets, envelope.modified)
    }
}
