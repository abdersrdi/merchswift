import Foundation

public enum DesignPackError: Error, Equatable, CustomStringConvertible {
    case notAPack
    case truncated
    case unsafeName(String)

    public var description: String {
        switch self {
        case .notAPack: return "This file is not a MerchSwift design file."
        case .truncated: return "This design file is incomplete. It may not have finished copying."
        case .unsafeName: return "This design file contains something unexpected and was not opened."
        }
    }
}

/// A design as one file, for backing up, moving to another device or sending to someone. It holds the same files as the
/// design's folder, one after another, with no compression (the pictures are PNG already).
///
/// Layout: the text `MSWPACK1`, then for each file: name length (4 bytes), the name (UTF-8), data length (8 bytes), the data.
/// Numbers are big endian.
public enum DesignPack {
    public static let fileExtension = "merchswiftpack"
    private static let magic = Data("MSWPACK1".utf8)

    /// Files a pack may hold. Anything else is refused, so a pack can never write outside the design folder.
    static func isAllowed(_ name: String) -> Bool {
        if name == "design.json" || name == "thumbnail.png" { return true }
        guard name.hasPrefix("assets/"), name.hasSuffix(".png") else { return false }
        let leaf = name.dropFirst("assets/".count)
        return !leaf.isEmpty && !leaf.contains("/") && !leaf.contains("\\") && !leaf.hasPrefix(".")
    }

    /// Packs the design folder into one file's worth of data.
    public static func make(from packageURL: URL) throws -> Data {
        let fm = FileManager.default
        var files: [(String, URL)] = []
        for top in ["design.json", "thumbnail.png"] {
            let u = packageURL.appendingPathComponent(top)
            if fm.fileExists(atPath: u.path) { files.append((top, u)) }
        }
        let assets = packageURL.appendingPathComponent("assets")
        for name in ((try? fm.contentsOfDirectory(atPath: assets.path)) ?? []).sorted() where isAllowed("assets/" + name) {
            files.append(("assets/" + name, assets.appendingPathComponent(name)))
        }
        guard files.contains(where: { $0.0 == "design.json" }) else { throw DesignFileError.notADesign }

        var out = magic
        func be32(_ v: UInt32) { out.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
        func be64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((v >> UInt64(s)) & 255)) } }
        for (name, url) in files {
            let data = try Data(contentsOf: url)
            let nameBytes = Data(name.utf8)
            be32(UInt32(nameBytes.count)); out.append(nameBytes)
            be64(UInt64(data.count)); out.append(data)
        }
        return out
    }

    /// The files inside a pack, by name. Refuses unexpected names and cut-off data.
    public static func files(in data: Data) throws -> [String: Data] {
        guard data.count >= magic.count, data.prefix(magic.count) == magic else { throw DesignPackError.notAPack }
        let bytes = [UInt8](data)
        var pos = magic.count
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, pos + n <= bytes.count else { throw DesignPackError.truncated }
            defer { pos += n }
            return bytes[pos..<pos + n]
        }
        var out: [String: Data] = [:]
        while pos < bytes.count {
            let nameLen = try take(4).reduce(0) { $0 << 8 | Int($1) }
            guard nameLen > 0, nameLen < 1024 else { throw DesignPackError.truncated }
            guard let name = String(bytes: try take(nameLen), encoding: .utf8) else { throw DesignPackError.notAPack }
            guard isAllowed(name) else { throw DesignPackError.unsafeName(name) }
            let lenSlice = try take(8)
            var length: UInt64 = 0
            for b in lenSlice { length = length << 8 | UInt64(b) }
            guard length <= UInt64(bytes.count - pos) else { throw DesignPackError.truncated }
            out[name] = Data(try take(Int(length)))
        }
        guard out["design.json"] != nil else { throw DesignPackError.notAPack }
        return out
    }

    /// Writes a pack's files out as a design folder at `url`, then checks that it opens. If it does not, nothing is left behind.
    public static func extract(_ data: Data, to url: URL) throws {
        let files = try files(in: data)
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".\(url.lastPathComponent).importing-\(UUID().uuidString)")
        try fm.createDirectory(at: temp.appendingPathComponent("assets"), withIntermediateDirectories: true)
        do {
            for (name, bytes) in files { try bytes.write(to: temp.appendingPathComponent(name)) }
            _ = try DesignPackage.read(from: temp)           // the description must be readable and not from a newer app
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: temp, to: url)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
