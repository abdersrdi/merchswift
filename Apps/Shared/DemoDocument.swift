import CoreGraphics
import CutLine
import DocumentModel
import Foundation
import Renderer

/// Pixels for the demo document's placed pictures, drawn in code.
final class DemoAssets: AssetProvider {
    private lazy var sunset: CGImage? = {
        let w = 600, h = 400
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(srgbRed: 0.98, green: 0.78, blue: 0.35, alpha: 1), CGColor(srgbRed: 0.93, green: 0.31, blue: 0.36, alpha: 1),
                      CGColor(srgbRed: 0.18, green: 0.14, blue: 0.40, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: .zero, options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.97, blue: 0.85, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 380, y: 170, width: 120, height: 120))
        return ctx.makeImage()
    }()

    func image(for assetID: String) -> CGImage? { assetID == "sunset" ? sunset : nil }
}

/// A 300 x 400 mm, 600 DPI t-shirt print with 60+ layers, to try the canvas on.
enum DemoDocument {
    static func make(extraLayers: Int = 0) -> Document {
        var layers: [Layer] = []
        layers.append(Layer(name: "Sunset", content: .image(ImageContent(assetID: "sunset", size: Size2(240, 160))),
                            transform: .translation(30, 30)))

        for i in 0..<60 {
            let col = Double(i % 10), row = Double(i / 10)
            let hue = Double(i) / 60
            let color = RGBA(0.5 + 0.5 * sin(hue * 6.28), 0.5 + 0.5 * sin(hue * 6.28 + 2.1), 0.5 + 0.5 * sin(hue * 6.28 + 4.2))
            let rect = Rect2(x: 0, y: 0, width: 22, height: 22)
            let path: PathData = i % 3 == 0 ? .ellipse(in: rect) : .rect(rect)
            layers.append(Layer(name: "Chip \(i + 1)", content: .shape(ShapeContent(path: path, fill: color,
                                stroke: i % 4 == 0 ? Stroke(color: .white, width: 1.2) : nil)),
                                transform: Transform2D.rotation(Double(i) * 0.05).then(.translation(34 + col * 26, 210 + row * 26)),
                                opacity: i % 5 == 0 ? 0.75 : 1, blendMode: i % 7 == 0 ? .multiply : .normal))
        }

        // A star outline built from curves, to see stroke quality when zoomed far in.
        var star: [PathData.Element] = []
        for k in 0..<10 {
            let r = k % 2 == 0 ? 60.0 : 26.0
            let a = Double(k) / 10 * 2 * .pi - .pi / 2
            let p = Point(r * cos(a), r * sin(a))
            star.append(k == 0 ? .move(p) : .line(p))
        }
        star.append(.close)
        layers.append(Layer(name: "Star", content: .shape(ShapeContent(path: PathData(elements: star), fill: RGBA(1, 0.86, 0.2),
                            stroke: Stroke(color: RGBA(0.1, 0.1, 0.12), width: 2.5))), transform: .translation(150, 105)))

        for i in 0..<extraLayers {
            let x = Double((i * 37) % 260) + 10, y = Double((i * 53) % 360) + 10
            layers.append(Layer(name: "Extra \(i + 1)", content: .shape(ShapeContent(
                path: .ellipse(in: Rect2(x: 0, y: 0, width: 14, height: 14)), fill: RGBA(0, 0, 0, 0.35))),
                transform: .translation(x, y), blendMode: .multiply))
        }
        return Document(title: "Demo tee", size: Size2(300, 400), dpi: 600, presetID: "tee-front", layers: layers)
    }
}
