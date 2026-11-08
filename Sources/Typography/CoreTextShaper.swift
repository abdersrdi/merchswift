#if canImport(CoreText) && canImport(CoreGraphics)
import CoreGraphics
import CoreText
import CutLine
import DocumentModel
import Editor
import Foundation

/// Lays text out with Core Text, which does the script shaping (Arabic joining, ligatures, marks, OpenType
/// features) and the bidirectional ordering, and turns the glyphs into vector outlines. Everything the rest of the
/// app does with text (drawing, PDF, PNG, SVG, cut lines) then works on those outlines, so the result is identical
/// everywhere.
public final class CoreTextShaper: TextShaping {
    public let fonts: FontLibrary

    public init(fonts: FontLibrary = .shared) { self.fonts = fonts }

    public func shape(text: String, style: TextStyle, boxWidth: Double?) -> ShapedText {
        let laid = layout(text: text, style: style, boxWidth: boxWidth)
        guard let curve = style.curve else { return ShapedText(outline: laid.outline, size: laid.size) }
        let bent = TextWarp.apply(curve, to: laid.outline, blockWidth: laid.size.width, baseline: laid.firstBaseline)
        return ShapedText(outline: bent, size: laid.size)
    }

    // MARK: Layout

    struct Layout {
        var outline: PathData
        var size: Size2
        var firstBaseline: Double
        var runs: [DebugRun]
        var glyphCount: Int
    }

    /// One shaped run, for tests: the characters it covers and where its first glyph sits.
    public struct DebugRun: Equatable {
        public var range: NSRange
        public var x: Double
        public var glyphs: Int
    }

    public func debugRuns(text: String, style: TextStyle, boxWidth: Double? = nil) -> [DebugRun] {
        layout(text: text, style: style, boxWidth: boxWidth).runs
    }

    public func glyphCount(text: String, style: TextStyle) -> Int {
        layout(text: text, style: style, boxWidth: nil).glyphCount
    }

    func layout(text: String, style: TextStyle, boxWidth: Double?) -> Layout {
        let font = fonts.font(for: style, size: style.size)
        let ascent = Double(CTFontGetAscent(font)), descent = Double(CTFontGetDescent(font)), leading = Double(CTFontGetLeading(font))
        let lineHeight = (ascent + descent + leading) * style.lineSpacing

        var path = PathData()
        var runsOut: [DebugRun] = []
        var glyphTotal = 0
        var lines: [(line: CTLine, rtl: Bool, isLastOfParagraph: Bool, utf16Offset: Int)] = []

        // Paragraphs are separated by newlines; each gets its own direction and line breaking.
        var utf16Start = 0
        let paragraphs = text.components(separatedBy: "\n")
        for paragraph in paragraphs {
            let ns = paragraph as NSString
            defer { utf16Start += ns.length + 1 }
            if ns.length == 0 { lines.append((CTLineCreateWithAttributedString(NSAttributedString(string: "")), false, true, utf16Start)); continue }

            let attributed = attributedString(for: paragraph, style: style, font: font)
            let rtl = isRightToLeft(paragraph, style.direction)
            var options: [CFString: Any] = [:]
            if style.direction != .auto { options[kCTTypesetterOptionForcedEmbeddingLevel] = rtl ? 1 : 0 }
            guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(attributed as CFAttributedString, options as CFDictionary) else { continue }

            var start = 0
            let limit = boxWidth ?? 1_000_000
            while start < ns.length {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, limit)
                let range = CFRange(location: start, length: max(count, 1))
                let line = CTTypesetterCreateLine(typesetter, range)
                start += max(count, 1)
                lines.append((line, rtl, start >= ns.length, utf16Start))
            }
        }

        // The block is as wide as its widest line, or as the box when there is one.
        func visibleWidth(_ line: CTLine) -> Double {
            Double(CTLineGetTypographicBounds(line, nil, nil, nil)) - Double(CTLineGetTrailingWhitespaceWidth(line))
        }
        let widest = lines.map { visibleWidth($0.line) }.max() ?? 0
        let container = boxWidth ?? widest

        for (index, entry) in lines.enumerated() {
            var line = entry.line
            if style.alignment == .justified, !entry.isLastOfParagraph, boxWidth != nil,
               let j = CTLineCreateJustifiedLine(line, 1.0, container) { line = j }

            let flush: Double
            switch style.alignment {
            case .start, .justified: flush = entry.rtl ? 1 : 0
            case .center: flush = 0.5
            case .end: flush = entry.rtl ? 0 : 1
            }
            let width = visibleWidth(line)
            let x0 = flush * (container - width)
            let baseline = ascent + Double(index) * lineHeight

            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let runFont: CTFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                // A ligature can leave a deleted-glyph placeholder (0xFFFF) behind; it is not a drawn glyph.
                glyphTotal += glyphs.filter { $0 != 0xFFFF }.count
                let r = CTRunGetStringRange(run)
                runsOut.append(DebugRun(range: NSRange(location: r.location + entry.utf16Offset, length: r.length),
                                        x: x0 + Double(positions[0].x), glyphs: count))

                for (g, pos) in zip(glyphs, positions) {
                    guard let cg = CTFontCreatePathForGlyph(runFont, g, nil) else { continue }
                    append(cg, offsetX: x0 + Double(pos.x), baseline: baseline - Double(pos.y), to: &path)
                }
            }
        }

        let height = Double(max(lines.count, 1)) * lineHeight
        return Layout(outline: path, size: Size2(container, height), firstBaseline: ascent, runs: runsOut, glyphCount: glyphTotal)
    }

    // MARK: Attributes

    private func attributedString(for text: String, style: TextStyle, font: CTFont) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: s.length)
        s.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: font, range: full)
        if let language = style.language {
            s.addAttribute(NSAttributedString.Key(kCTLanguageAttributeName as String), value: language, range: full)
        }
        if style.tracking != 0 {
            // Letter spacing breaks Arabic, whose letters must stay joined, so it only touches other scripts.
            let kern = style.tracking / 1000 * style.size
            let ns = text as NSString
            var i = 0
            while i < ns.length {
                let c = ns.character(at: i)
                let arabic = Self.isArabicScript(c)
                if !arabic && !(c == 0x20 && i > 0 && Self.isArabicScript(ns.character(at: i - 1))) {
                    s.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: kern, range: NSRange(location: i, length: 1))
                }
                i += 1
            }
        }
        return s
    }

    static func isArabicScript(_ c: unichar) -> Bool {
        (0x0600...0x06FF).contains(c) || (0x0750...0x077F).contains(c) || (0x08A0...0x08FF).contains(c)
            || (0xFB50...0xFDFF).contains(c) || (0xFE70...0xFEFF).contains(c) || c == 0x200D || c == 0x200C
    }

    /// The paragraph's direction: as set, or from its first strong letter.
    func isRightToLeft(_ paragraph: String, _ direction: TextDirection) -> Bool {
        switch direction {
        case .rightToLeft: return true
        case .leftToRight: return false
        case .auto:
            for scalar in paragraph.unicodeScalars {
                let v = scalar.value
                if (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) { return true }
                if scalar.properties.isAlphabetic { return false }
            }
            return false
        }
    }

    // MARK: Outlines

    /// Appends a glyph's outline, flipped to y-down and moved into place. Quadratic curves (TrueType) become cubics.
    private func append(_ cg: CGPath, offsetX: Double, baseline: Double, to out: inout PathData) {
        var current = Point(0, 0)
        func map(_ p: CGPoint) -> Point { Point(offsetX + Double(p.x), baseline - Double(p.y)) }
        cg.applyWithBlock { elementPointer in
            let e = elementPointer.pointee
            let pts = e.points
            switch e.type {
            case .moveToPoint:
                current = map(pts[0]); out.elements.append(.move(current))
            case .addLineToPoint:
                current = map(pts[0]); out.elements.append(.line(current))
            case .addQuadCurveToPoint:
                let c = map(pts[0]), p = map(pts[1])
                let c1 = current + (c - current) * (2.0 / 3.0), c2 = p + (c - p) * (2.0 / 3.0)
                out.elements.append(.cubic(c1, c2, p)); current = p
            case .addCurveToPoint:
                let a = map(pts[0]), b = map(pts[1]), p = map(pts[2])
                out.elements.append(.cubic(a, b, p)); current = p
            case .closeSubpath:
                out.elements.append(.close)
            @unknown default: break
            }
        }
    }
}
#endif
