import Foundation

/// A small PNG encoder that works on every platform. It writes the image data uncompressed (stored deflate blocks),
/// which is simple and exact; it is used for pictures embedded in SVG files and for tests. The app's PNG export uses
/// ImageIO, which compresses.
public enum PNGEncoder {
    /// - Parameter dpi: written as the physical pixel size, so print software opens the file at the right size.
    public static func encode(_ image: RGBAImage, dpi: Double? = nil) -> Data {
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func chunk(_ type: String, _ body: [UInt8]) {
            let t = Array(type.utf8)
            out.append(contentsOf: be32(UInt32(body.count)))
            out.append(contentsOf: t)
            out.append(contentsOf: body)
            out.append(contentsOf: be32(CRC32.checksum(t + body)))
        }

        chunk("IHDR", be32(UInt32(image.width)) + be32(UInt32(image.height)) + [8, 6, 0, 0, 0])
        if let dpi, dpi > 0 {
            let perMetre = UInt32((dpi / 0.0254).rounded())
            chunk("pHYs", be32(perMetre) + be32(perMetre) + [1])
        }

        // Each row starts with filter type 0 (none).
        var raw = [UInt8]()
        raw.reserveCapacity((image.width * 4 + 1) * image.height)
        for y in 0..<image.height {
            raw.append(0)
            raw.append(contentsOf: image.pixels[(y * image.width * 4)..<((y + 1) * image.width * 4)])
        }

        // zlib stream: header, stored blocks of up to 65535 bytes, Adler-32.
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        while i < raw.count || raw.isEmpty && i == 0 {
            let n = min(65535, raw.count - i)
            let last = i + n >= raw.count
            z.append(last ? 1 : 0)
            z.append(UInt8(n & 0xFF)); z.append(UInt8(n >> 8))
            z.append(UInt8(~n & 0xFF)); z.append(UInt8((~n >> 8) & 0xFF))
            z.append(contentsOf: raw[i..<(i + n)])
            i += n
            if raw.isEmpty { break }
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        z.append(contentsOf: be32((b << 16) | a))
        chunk("IDAT", z)
        chunk("IEND", [])
        return out
    }
}
