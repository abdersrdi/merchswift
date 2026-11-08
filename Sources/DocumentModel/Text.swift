import CutLine
import Foundation

public enum TextAlignment: String, Codable, CaseIterable {
    /// The side the text starts on: left for left-to-right paragraphs, right for Arabic.
    case start, center, end, justified
}

public enum TextDirection: String, Codable, CaseIterable {
    /// Decided per paragraph from its first strong letter.
    case auto, rightToLeft, leftToRight
}

/// An OpenType feature switched on or off, by its four-letter tag: "liga", "dlig", "swsh", "ss01", "smcp", "tnum"...
public struct FontFeature: Codable, Equatable, Hashable {
    public var tag: String
    public var value: Int
    public init(_ tag: String, _ value: Int = 1) { self.tag = tag; self.value = value }
}

/// How the text is bent after it has been laid out on a straight baseline.
public enum TextCurve: Codable, Equatable {
    /// An arc: the baseline of the first line becomes part of a circle that turns through `degrees`.
    /// Positive bends the ends down (a rainbow), negative bends them up (a smile).
    case arc(degrees: Double)
    /// Along a path in the layer's own coordinates, starting `offset` millimetres along it.
    case path(PathData, offset: Double)
}

public struct TextStyle: Codable, Equatable {
    /// A family name from the font library ("Cairo", "Amiri", "Montserrat"...).
    public var family: String
    /// 100 (thin) ... 900 (black). Fonts without a weight axis snap to their nearest static style.
    public var weight: Double
    public var italic: Bool
    /// The em size in millimetres.
    public var size: Double
    /// Extra space after each letter, in thousandths of an em. Not applied to Arabic, which must stay joined.
    public var tracking: Double
    /// 1 is the font's own line height.
    public var lineSpacing: Double
    public var alignment: TextAlignment
    public var direction: TextDirection
    public var features: [FontFeature]
    /// A BCP 47 language code ("ar", "fr", "en") for fonts that change letter forms by language.
    public var language: String?
    public var curve: TextCurve?
    public var fill: RGBA
    public var stroke: Stroke?

    public init(family: String = "Cairo", weight: Double = 400, italic: Bool = false, size: Double = 20,
                tracking: Double = 0, lineSpacing: Double = 1, alignment: TextAlignment = .start,
                direction: TextDirection = .auto, features: [FontFeature] = [], language: String? = nil,
                curve: TextCurve? = nil, fill: RGBA = .black, stroke: Stroke? = nil) {
        self.family = family; self.weight = weight; self.italic = italic; self.size = size
        self.tracking = tracking; self.lineSpacing = lineSpacing; self.alignment = alignment
        self.direction = direction; self.features = features; self.language = language
        self.curve = curve; self.fill = fill; self.stroke = stroke
    }
}

/// What a text layer holds: the words and style the user edits, and the outline they produce.
/// The outline is kept so the layer draws, exports and measures the same everywhere without needing the font again.
public struct TextContent: Codable, Equatable {
    public var text: String
    public var style: TextStyle
    /// A wrapping width in millimetres, or nil for text that grows as you type.
    public var boxWidth: Double?
    /// Glyph outlines in the layer's own coordinates: origin at the top left of the text block, y down.
    public var outline: PathData
    /// Size of the laid-out block before any curve is applied.
    public var size: Size2

    public init(text: String, style: TextStyle = TextStyle(), boxWidth: Double? = nil,
                outline: PathData = PathData(), size: Size2 = Size2(0, 0)) {
        self.text = text; self.style = style; self.boxWidth = boxWidth; self.outline = outline; self.size = size
    }
}

public struct ShapedText: Equatable {
    public var outline: PathData
    public var size: Size2
    public init(outline: PathData, size: Size2) { self.outline = outline; self.size = size }
}

/// Turns words and a style into outlines. The real one uses Core Text; tests use a stand-in.
public protocol TextShaping: AnyObject {
    func shape(text: String, style: TextStyle, boxWidth: Double?) -> ShapedText
}

public extension TextContent {
    /// Lays the text out again with `shaper` and stores the result.
    mutating func reshape(using shaper: TextShaping) {
        let shaped = shaper.shape(text: text, style: style, boxWidth: boxWidth)
        outline = shaped.outline
        size = shaped.size
    }
}

public extension Document {
    /// Re-lays out every text layer, for a document opened where its outlines were never made or fonts changed.
    mutating func reshapeAllText(using shaper: TextShaping) {
        func visit(_ layers: inout [Layer]) {
            for i in layers.indices {
                switch layers[i].content {
                case .text(var t):
                    t.reshape(using: shaper)
                    layers[i].content = .text(t)
                case .group(var kids):
                    visit(&kids)
                    layers[i].content = .group(kids)
                default: break
                }
            }
        }
        visit(&layers)
    }
}
