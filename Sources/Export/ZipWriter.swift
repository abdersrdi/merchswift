import Foundation

/// CRC-32 as used by ZIP and PNG.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    static func checksum(_ data: Data) -> UInt32 { checksum([UInt8](data)) }
}

/// A ZIP archive built in memory, for "Export all". Files are stored without compression (PDF and PNG are already
/// compressed) and every date is fixed, so the same files always give the same archive.
public struct ZipWriter {
    public struct Entry: Equatable {
        public var name: String
        public var data: Data
        public init(name: String, data: Data) { self.name = name; self.data = data }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func add(name: String, data: Data) {
        entries.append(Entry(name: name, data: data))
    }

    public func data() -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        let dosTime = 0, dosDate = (0 << 9) | (1 << 5) | 1                // 1980-01-01 00:00:00

        for e in entries {
            let name = Array(e.name.utf8)
            let crc = CRC32.checksum(e.data)
            let offset = UInt32(out.count)
            var local: [UInt8] = []
            local += u32(0x04034B50)
            local += u16(20)                                                // version needed
            local += u16(0x0800)                                            // flags: UTF-8 names
            local += u16(0)                                                 // stored
            local += u16(dosTime) + u16(dosDate)
            local += u32(crc) + u32(UInt32(e.data.count)) + u32(UInt32(e.data.count))
            local += u16(name.count) + u16(0)
            out.append(contentsOf: local)
            out.append(contentsOf: name)
            out.append(e.data)

            var c: [UInt8] = []
            c += u32(0x02014B50)
            c += u16(20) + u16(20)                                          // made by, needed
            c += u16(0x0800) + u16(0)
            c += u16(dosTime) + u16(dosDate)
            c += u32(crc) + u32(UInt32(e.data.count)) + u32(UInt32(e.data.count))
            c += u16(name.count) + u16(0) + u16(0)                          // name, extra, comment lengths
            c += u16(0) + u16(0) + u32(0)                                   // disk, internal attrs, external attrs
            c += u32(offset)
            central.append(contentsOf: c)
            central.append(contentsOf: name)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)
        var end: [UInt8] = []
        end += u32(0x06054B50)
        end += u16(0) + u16(0)
        end += u16(entries.count) + u16(entries.count)
        end += u32(UInt32(central.count)) + u32(centralOffset)
        end += u16(0)
        out.append(contentsOf: end)
        return out
    }
}
