import CutLine
import DocumentModel
import Foundation

/// The small mark free exports carry. It sits in the bottom right corner, inside the bleed and safe margin, on top of
/// the artwork. Watching a short video, or Pro, removes it.
public enum Watermark {
    /// - Parameters:
    ///   - text: what the mark says.
    ///   - widthFraction: how wide it is, as a fraction of the canvas width.
    ///   - inset: distance from the canvas edges in millimetres. It must clear the bleed and the safe margin.
    public static func layer(for doc: Document, shaper: TextShaping, text: String = "MerchSwift",
                             widthFraction: Double = 0.32, inset: Double = 8) -> Layer {
        // Lay it out once at a trial size, then scale the size so the mark has the width it should.
        func content(_ em: Double) -> TextContent {
            let style = TextStyle(family: "Cairo", weight: 700, size: em, fill: RGBA(1, 1, 1, 0.9),
                                  stroke: Stroke(color: RGBA(0, 0, 0, 0.55), width: max(em * 0.05, 0.1)))
            var c = TextContent(text: text, style: style)
            c.reshape(using: shaper)
            return c
        }
        let trial = content(10)
        let trialWidth = max(trial.outline.bounds?.width ?? trial.size.width, 0.001)
        let targetWidth = doc.size.width * widthFraction
        let final = content(10 * targetWidth / trialWidth)
        let b = final.outline.bounds ?? Rect2(x: 0, y: 0, width: targetWidth, height: final.style.size)

        // Move the outline's own bottom right corner to the canvas corner minus the inset.
        let tx = doc.size.width - inset - b.maxX
        let ty = doc.size.height - inset - b.maxY
        return Layer(name: "Watermark", content: .text(final), transform: .translation(tx, ty), isLocked: true)
    }
}
