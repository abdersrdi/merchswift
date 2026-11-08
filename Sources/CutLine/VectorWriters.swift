import Foundation

private func fmt(_ v: Double, _ digits: Int = 3) -> String {
    var s = String(format: "%.\(digits)f", v)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s == "-0" ? "0" : s
}

public enum SVGWriter {
    /// SVG with the cut line as one path. `cut` is in millimetres, y down, origin top left.
    /// If `artworkPNG` is given it is embedded as an image covering the whole page.
    public static func svg(cut: CutPath, widthMM: Double, heightMM: Double, artworkPNG: Data? = nil) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" "
        out += "width=\"\(fmt(widthMM))mm\" height=\"\(fmt(heightMM))mm\" viewBox=\"0 0 \(fmt(widthMM)) \(fmt(heightMM))\">\n"
        if let png = artworkPNG {
            out += "  <image id=\"Artwork\" x=\"0\" y=\"0\" width=\"\(fmt(widthMM))\" height=\"\(fmt(heightMM))\" "
            out += "xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>\n"
        }
        out += "  <path id=\"CutContour\" fill=\"none\" stroke=\"#ff00ff\" stroke-width=\"0.1\" d=\""
        out += pathData(cut)
        out += "\"/>\n</svg>\n"
        return out
    }

    public static func pathData(_ cut: CutPath) -> String {
        var d = ""
        for c in cut.contours {
            guard let first = c.segments.first else { continue }
            d += "M\(fmt(first.p0.x)) \(fmt(first.p0.y))"
            for s in c.segments {
                d += "C\(fmt(s.p1.x)) \(fmt(s.p1.y)) \(fmt(s.p2.x)) \(fmt(s.p2.y)) \(fmt(s.p3.x)) \(fmt(s.p3.y))"
            }
            d += "Z"
        }
        return d
    }
}

public enum DXFWriter {
    /// DXF (R12, the version every cutter reads) with each contour as a closed polyline on layer `CutContour`.
    /// `cut` is in millimetres with y up (use `CutPath.flippedY`).
    public static func dxf(cut: CutPath, layer: String = "CutContour") -> String {
        var s = ""
        func g(_ code: Int, _ value: String) { s += "\(code)\n\(value)\n" }

        g(0, "SECTION"); g(2, "HEADER")
        g(9, "$ACADVER"); g(1, "AC1009")
        g(9, "$INSUNITS"); g(70, "4")
        g(0, "ENDSEC")

        g(0, "SECTION"); g(2, "TABLES")
        g(0, "TABLE"); g(2, "LAYER"); g(70, "1")
        g(0, "LAYER"); g(2, layer); g(70, "0"); g(62, "6"); g(6, "CONTINUOUS")
        g(0, "ENDTAB")
        g(0, "ENDSEC")

        g(0, "SECTION"); g(2, "ENTITIES")
        for contour in cut.contours {
            let pts = flatten(contour, tolerance: 0.01)
            guard pts.count >= 3 else { continue }
            g(0, "POLYLINE"); g(8, layer); g(66, "1"); g(70, "1")
            for p in pts {
                g(0, "VERTEX"); g(8, layer)
                g(10, fmt(p.x, 4)); g(20, fmt(p.y, 4)); g(30, "0")
            }
            g(0, "SEQEND"); g(8, layer)
        }
        g(0, "ENDSEC")
        g(0, "EOF")
        return s
    }

    /// Straight-line approximation of the outline whose largest deviation from the curve is about `tolerance`.
    static func flatten(_ c: Contour, tolerance: Double) -> [Point] {
        var out: [Point] = []
        for seg in c.segments {
            // Deviation of a cubic split into n parts is bounded by roughly L * kappa / (8 n^2); pick n from the
            // second difference of the control polygon.
            let dd0 = seg.p0 - seg.p1 * 2 + seg.p2
            let dd1 = seg.p1 - seg.p2 * 2 + seg.p3
            let m = max(dd0.length, dd1.length)
            let n = max(4, min(400, Int((0.75 * m / tolerance).squareRoot().rounded(.up))))
            for i in 0..<n { out.append(seg.point(at: Double(i) / Double(n))) }
        }
        return out
    }
}
