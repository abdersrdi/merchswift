import CutLine
import DocumentModel
import Foundation

/// The drawing of a document as PDF content stream text, built without touching the PDF library so it can be read,
/// tested against golden files and reused. User space is canvas millimetres with y down; the page applies one
/// matrix to turn that into points with y up.
struct PDFGraphicsState: Equatable {
    /// `ca`: opacity of fills and images.
    var fillAlpha: Double
    /// `CA`: opacity of strokes.
    var strokeAlpha: Double
    var blendMode: String
}

struct PDFFormScope {
    var name: String
    var scope: PDFScope
    var bbox: Rect2
}

final class PDFScope {
    var content = ""
    /// Resource name to the asset it shows.
    var images: [String: ImageRef] = [:]
    var forms: [PDFFormScope] = []
    var states: [String: PDFGraphicsState] = [:]

    struct ImageRef: Equatable { var assetID: String }
}

struct PDFContentBuilder {
    /// Lets the caller leave out images whose pixels are not available, so the file never refers to a missing one.
    private var hasImage: ((String) -> Bool)?
    private var imageCounter = 0
    private var formCounter = 0
    private var stateCounter = 0

    /// The page's content, plus everything it uses, from the visible layers.
    static func build(_ doc: Document, hasImage: ((String) -> Bool)? = nil) -> PDFScope {
        var builder = PDFContentBuilder()
        builder.hasImage = hasImage
        let page = PDFScope()
        for layer in doc.layers { builder.emit(layer, into: page) }
        return page
    }

    // MARK: Layers

    private mutating func emit(_ layer: Layer, into scope: PDFScope) {
        guard layer.isVisible else { return }
        let t = layer.transform
        let cm = "\(PDFContentBuilder.num(t.a)) \(PDFContentBuilder.num(t.b)) \(PDFContentBuilder.num(t.c)) \(PDFContentBuilder.num(t.d)) \(PDFContentBuilder.num(t.tx)) \(PDFContentBuilder.num(t.ty)) cm"

        if layer.opacity < 1 || layer.blendMode != .normal {
            // Opacity and blend modes apply to the layer as a whole: draw it into a transparency group.
            let inner = PDFScope()
            body(of: layer, into: inner)
            formCounter += 1
            let form = PDFFormScope(name: "Fm\(formCounter)", scope: inner, bbox: Self.formBounds(layer))
            scope.forms.append(form)
            let gs = state(alpha: layer.opacity, blend: layer.blendMode, in: scope)
            scope.content += "q \(cm) /\(gs) gs /\(form.name) Do Q\n"
        } else {
            scope.content += "q \(cm)\n"
            body(of: layer, into: scope)
            scope.content += "Q\n"
        }
    }

    private mutating func body(of layer: Layer, into scope: PDFScope) {
        switch layer.content {
        case .group(let kids):
            for k in kids { emit(k, into: scope) }
        case .shape(let s):
            paint(s.path, fill: s.fill, stroke: s.stroke, into: scope)
        case .text(let t):
            paint(t.outline, fill: t.style.fill, stroke: t.style.stroke, into: scope)
        case .image(let i):
            if let hasImage, !hasImage(i.assetID) { return }
            imageCounter += 1
            let name = "Im\(imageCounter)"
            scope.images[name] = PDFScope.ImageRef(assetID: i.assetID)
            // An image is a unit square with y up; flip it into the y-down space and scale it to its size.
            scope.content += "q \(Self.num(i.size.width)) 0 0 \(Self.num(-i.size.height)) 0 \(Self.num(i.size.height)) cm /\(name) Do Q\n"
        }
    }

    private mutating func paint(_ path: PathData, fill: RGBA?, stroke: Stroke?, into scope: PDFScope) {
        guard !path.elements.isEmpty, fill != nil || (stroke?.width ?? 0) > 0 else { return }
        let hasStroke = (stroke?.width ?? 0) > 0
        let fillAlpha = fill?.a ?? 1, strokeAlpha = hasStroke ? (stroke?.color.a ?? 1) : 1
        if fillAlpha < 1 || strokeAlpha < 1 {
            stateCounter += 1
            let name = "GS\(stateCounter)"
            scope.states[name] = PDFGraphicsState(fillAlpha: fillAlpha, strokeAlpha: strokeAlpha, blendMode: "Normal")
            scope.content += "/\(name) gs\n"
        }
        scope.content += Self.pathOps(path)
        if let f = fill { scope.content += "/CS0 cs \(Self.color(f)) sc\n" }
        if hasStroke, let st = stroke {
            scope.content += "/CS0 CS \(Self.color(st.color)) SC \(Self.num(st.width)) w 1 J 1 j\n"
        }
        switch (fill != nil, hasStroke) {
        case (true, true): scope.content += "B\n"
        case (true, false): scope.content += "f\n"
        default: scope.content += "S\n"
        }
    }

    private mutating func state(alpha: Double, blend: BlendMode, in scope: PDFScope) -> String {
        stateCounter += 1
        let name = "GS\(stateCounter)"
        scope.states[name] = PDFGraphicsState(fillAlpha: alpha, strokeAlpha: alpha, blendMode: Self.blendName(blend))
        return name
    }

    // MARK: Pieces

    static func pathOps(_ p: PathData) -> String {
        var s = ""
        for e in p.elements {
            switch e {
            case .move(let a): s += "\(num(a.x)) \(num(a.y)) m\n"
            case .line(let a): s += "\(num(a.x)) \(num(a.y)) l\n"
            case .cubic(let a, let b, let c): s += "\(num(a.x)) \(num(a.y)) \(num(b.x)) \(num(b.y)) \(num(c.x)) \(num(c.y)) c\n"
            case .close: s += "h\n"
            }
        }
        return s
    }

    static func color(_ c: RGBA) -> String { "\(num(min(max(c.r, 0), 1))) \(num(min(max(c.g, 0), 1))) \(num(min(max(c.b, 0), 1)))" }

    static func blendName(_ m: BlendMode) -> String {
        switch m {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        case .colorDodge: return "ColorDodge"
        case .colorBurn: return "ColorBurn"
        case .softLight: return "SoftLight"
        case .hardLight: return "HardLight"
        case .difference: return "Difference"
        }
    }

    /// The area a group's content may draw in, in the layer's own coordinates, with room for strokes.
    static func formBounds(_ layer: Layer) -> Rect2 {
        if let b = layer.localBounds {
            return Rect2(x: b.x - 2, y: b.y - 2, width: b.width + 4, height: b.height + 4)
        }
        return Rect2(x: -10000, y: -10000, width: 20000, height: 20000)
    }

    /// A number with at most five decimals and no trailing zeros, the same on every platform.
    static func num(_ v: Double) -> String {
        if v == 0 { return "0" }
        var s = String(format: "%.5f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}

/// A readable dump of how a document turns into PDF content, for golden-file tests and debugging.
public enum PDFDescription {
    public static func describe(_ doc: Document) -> String {
        let page = PDFContentBuilder.build(doc)
        var out = ""
        func dump(_ title: String, _ scope: PDFScope) {
            out += "== \(title)\n\(scope.content)"
            for (name, ref) in scope.images.sorted(by: { $0.key < $1.key }) { out += "-- image \(name) = \(ref.assetID)\n" }
            for (name, st) in scope.states.sorted(by: { $0.key < $1.key }) { out += "-- state \(name) ca=\(PDFContentBuilder.num(st.fillAlpha)) CA=\(PDFContentBuilder.num(st.strokeAlpha)) blend=\(st.blendMode)\n" }
            for f in scope.forms {
                let b = f.bbox
                out += "-- form \(f.name) bbox=[\(PDFContentBuilder.num(b.minX)) \(PDFContentBuilder.num(b.minY)) \(PDFContentBuilder.num(b.maxX)) \(PDFContentBuilder.num(b.maxY))]\n"
            }
            for f in scope.forms { dump(f.name, f.scope) }
        }
        dump("page", page)
        return out
    }
}
