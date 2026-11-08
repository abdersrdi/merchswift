import CutLine
import Foundation

public enum BlendMode: String, Codable, CaseIterable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight, difference
}

public struct Stroke: Codable, Equatable {
    public var color: RGBA
    /// Line width in millimetres.
    public var width: Double
    public init(color: RGBA, width: Double) { self.color = color; self.width = width }
}

public struct ShapeContent: Codable, Equatable {
    public var path: PathData
    public var fill: RGBA?
    public var stroke: Stroke?
    public init(path: PathData, fill: RGBA? = nil, stroke: Stroke? = nil) {
        self.path = path; self.fill = fill; self.stroke = stroke
    }
}

/// A placed image. The pixels live in the document package under `assetID`; this only says where it goes.
public struct ImageContent: Codable, Equatable {
    public var assetID: String
    /// Size of the image in the layer's own coordinates, in millimetres, with its top left corner at the origin.
    public var size: Size2
    /// The pixels the original image has, so print resolution can be checked. Nil when unknown.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public init(assetID: String, size: Size2, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.assetID = assetID; self.size = size; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

public enum LayerContent: Codable, Equatable {
    case group([Layer])
    case shape(ShapeContent)
    case image(ImageContent)
    case text(TextContent)
}

public struct Layer: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    public var isLocked: Bool
    public var opacity: Double
    public var blendMode: BlendMode
    /// Maps the layer's own coordinates into its parent's.
    public var transform: Transform2D
    public var content: LayerContent

    public init(id: UUID = UUID(), name: String, content: LayerContent, transform: Transform2D = .identity,
                opacity: Double = 1, blendMode: BlendMode = .normal, isVisible: Bool = true, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.content = content
        self.transform = transform
        self.opacity = opacity
        self.blendMode = blendMode
        self.isVisible = isVisible
        self.isLocked = isLocked
    }

    public var children: [Layer] {
        if case .group(let c) = content { return c }
        return []
    }

    /// Bounds in the layer's own coordinates, before its own transform. Nil for an empty group or empty path.
    public var localBounds: Rect2? {
        switch content {
        case .shape(let s):
            guard var r = s.path.bounds else { return nil }
            if let w = s.stroke?.width {
                r = Rect2(x: r.x - w / 2, y: r.y - w / 2, width: r.width + w, height: r.height + w)
            }
            return r
        case .image(let i):
            return Rect2(x: 0, y: 0, width: i.size.width, height: i.size.height)
        case .text(let t):
            guard var r = t.outline.bounds else {
                // Not laid out yet: use the block size so the layer can still be found and selected.
                return t.size.width > 0 && t.size.height > 0 ? Rect2(x: 0, y: 0, width: t.size.width, height: t.size.height) : nil
            }
            if let w = t.style.stroke?.width {
                r = Rect2(x: r.x - w / 2, y: r.y - w / 2, width: r.width + w, height: r.height + w)
            }
            return r
        case .group(let kids):
            var out: Rect2?
            for k in kids where k.isVisible {
                guard let b = k.boundsInParent else { continue }
                out = out.map { $0.union(b) } ?? b
            }
            return out
        }
    }

    /// Bounds in the parent's coordinates (after this layer's transform).
    public var boundsInParent: Rect2? { localBounds.map { transform.apply($0) } }
}
