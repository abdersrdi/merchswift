import CutLine
import DocumentModel
import Foundation

/// A design as SVG: shapes and text outlines as paths, groups as groups, images embedded as PNG, blend modes as
/// CSS, and the cut line as its own path with the id `CutContour`. Units are millimetres.
public enum DocumentSVG {
    public static func svg(_ doc: Document, assets: PixelSource? = nil, cutLine: CutPath? = nil) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" "
        out += "width=\"\(n(doc.size.width))mm\" height=\"\(n(doc.size.height))mm\" viewBox=\"0 0 \(n(doc.size.width)) \(n(doc.size.height))\">\n"
        for l in doc.layers { emit(l, assets: assets, indent: "  ", into: &out) }
        if let cut = cutLine, !cut.contours.isEmpty {
            out += "  <path id=\"CutContour\" fill=\"none\" stroke=\"#ff00ff\" stroke-width=\"0.1\" d=\"\(SVGWriter.pathData(cut))\"/>\n"
        }
        out += "</svg>\n"
        return out
    }

    private static func emit(_ layer: Layer, assets: PixelSource?, indent: String, into out: inout String) {
        guard layer.isVisible else { return }
        var attrs = ""
        let t = layer.transform
        if t != .identity { attrs += " transform=\"matrix(\(n(t.a)) \(n(t.b)) \(n(t.c)) \(n(t.d)) \(n(t.tx)) \(n(t.ty)))\"" }
        if layer.opacity < 1 { attrs += " opacity=\"\(n(layer.opacity))\"" }
        if layer.blendMode != .normal { attrs += " style=\"mix-blend-mode:\(cssBlend(layer.blendMode))\"" }
        let id = " id=\"\(escape(layer.name))\""

        switch layer.content {
        case .group(let kids):
            out += "\(indent)<g\(id)\(attrs)>\n"
            for k in kids { emit(k, assets: assets, indent: indent + "  ", into: &out) }
            out += "\(indent)</g>\n"
        case .shape(let s):
            out += "\(indent)<path\(id)\(attrs)\(paint(s.fill, s.stroke)) d=\"\(pathData(s.path))\"/>\n"
        case .text(let tx):
            out += "\(indent)<path\(id)\(attrs)\(paint(tx.style.fill, tx.style.stroke)) d=\"\(pathData(tx.outline))\"/>\n"
        case .image(let i):
            var href = ""
            if let px = assets?.pixels(for: i.assetID) { href = " xlink:href=\"data:image/png;base64,\(PNGEncoder.encode(px).base64EncodedString())\"" }
            out += "\(indent)<image\(id)\(attrs) x=\"0\" y=\"0\" width=\"\(n(i.size.width))\" height=\"\(n(i.size.height))\" preserveAspectRatio=\"none\"\(href)/>\n"
        }
    }

    private static func paint(_ fill: RGBA?, _ stroke: Stroke?) -> String {
        var s = ""
        if let f = fill { s += " fill=\"\(hex(f))\"" + (f.a < 1 ? " fill-opacity=\"\(n(f.a))\"" : "") } else { s += " fill=\"none\"" }
        if let st = stroke, st.width > 0 {
            s += " stroke=\"\(hex(st.color))\" stroke-width=\"\(n(st.width))\" stroke-linejoin=\"round\" stroke-linecap=\"round\""
            if st.color.a < 1 { s += " stroke-opacity=\"\(n(st.color.a))\"" }
        }
        return s
    }

    static func pathData(_ p: PathData) -> String {
        var d = ""
        for e in p.elements {
            switch e {
            case .move(let a): d += "M\(n(a.x)) \(n(a.y))"
            case .line(let a): d += "L\(n(a.x)) \(n(a.y))"
            case .cubic(let a, let b, let c): d += "C\(n(a.x)) \(n(a.y)) \(n(b.x)) \(n(b.y)) \(n(c.x)) \(n(c.y))"
            case .close: d += "Z"
            }
        }
        return d
    }

    private static func hex(_ c: RGBA) -> String {
        func b(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#\(b(c.r))\(b(c.g))\(b(c.b))"
    }

    private static func cssBlend(_ m: BlendMode) -> String {
        switch m {
        case .normal: return "normal"
        case .multiply: return "multiply"
        case .screen: return "screen"
        case .overlay: return "overlay"
        case .darken: return "darken"
        case .lighten: return "lighten"
        case .colorDodge: return "color-dodge"
        case .colorBurn: return "color-burn"
        case .softLight: return "soft-light"
        case .hardLight: return "hard-light"
        case .difference: return "difference"
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func n(_ v: Double) -> String { PDFContentBuilder.num(v) }
}
