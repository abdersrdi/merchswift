#if canImport(CoreGraphics)
import CoreGraphics
import CutLine
import DocumentModel
import Editor
import Foundation

/// Supplies the pixels of placed images by asset ID.
public protocol AssetProvider: AnyObject {
    func image(for assetID: String) -> CGImage?
}

/// One rendered tile: premultiplied RGBA, 16-bit half floats (IEEE binary16 stored as UInt16),
/// in extended sRGB, row 0 at the top. 512 x 512 pixels.
public struct TilePixels {
    public let key: TileKey
    public var data: [UInt16]
}

public enum LayerRasterizer {
    /// Draws the part of the document that falls in one tile. Everything stays vector until this point:
    /// shapes are filled and stroked at the tile's own density, and images are resampled once.
    public static func render(_ document: Document, assets: AssetProvider?, tile key: TileKey) -> TilePixels? {
        let n = TileGrid.tilePixels
        var data = [UInt16](repeating: 0, count: n * n * 4)
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB) else { return nil }
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        let ok: Bool = data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 16,
                                      bytesPerRow: n * 8, space: space, bitmapInfo: info) else { return false }
            let rect = TileGrid.rect(of: key)
            let density = TileGrid.pixelsPerMM(level: key.level)

            // User space becomes canvas millimetres, y down, with the tile's top left at the context's top left.
            ctx.translateBy(x: 0, y: CGFloat(n))
            ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: CGFloat(density), y: CGFloat(density))
            ctx.translateBy(x: CGFloat(-rect.minX), y: CGFloat(-rect.minY))
            ctx.interpolationQuality = .high
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            draw(document.layers, in: ctx, parent: .identity, tile: rect, assets: assets)
            return true
        }
        return ok ? TilePixels(key: key, data: data) : nil
    }

    /// Draws the whole document into any Core Graphics context whose user space is canvas millimetres, y down
    /// (a bitmap, a PDF page, an SVG-like recorder). This is the one drawing routine for screen, PNG and PDF.
    public static func draw(_ document: Document, in ctx: CGContext, region: Rect2, assets: AssetProvider? = nil) {
        draw(document.layers, in: ctx, parent: .identity, tile: region, assets: assets)
    }

    // MARK: Drawing

    private static func draw(_ layers: [Layer], in ctx: CGContext, parent: Transform2D, tile: Rect2, assets: AssetProvider?) {
        for layer in layers where layer.isVisible && layer.opacity > 0 {
            let world = layer.transform.then(parent)
            if let local = layer.localBounds {
                let b = world.apply(local)
                if !b.intersects(tile) { continue }
            } else if case .group = layer.content {
                continue
            }

            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(a: layer.transform.a, b: layer.transform.b, c: layer.transform.c,
                                              d: layer.transform.d, tx: layer.transform.tx, ty: layer.transform.ty))

            let needsLayer: Bool
            switch layer.content {
            case .group: needsLayer = layer.opacity < 1 || layer.blendMode != .normal
            case .shape(let s): needsLayer = (layer.opacity < 1 || layer.blendMode != .normal) && s.fill != nil && s.stroke != nil
            case .image: needsLayer = false
            case .text(let t): needsLayer = (layer.opacity < 1 || layer.blendMode != .normal) && t.style.stroke != nil
            }

            ctx.setAlpha(CGFloat(layer.opacity))
            ctx.setBlendMode(cgBlend(layer.blendMode))
            if needsLayer {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setAlpha(1)
                ctx.setBlendMode(.normal)
            }

            switch layer.content {
            case .group(let kids):
                draw(kids, in: ctx, parent: world, tile: tile, assets: assets)
            case .shape(let s):
                drawShape(s, in: ctx)
            case .text(let t):
                drawShape(ShapeContent(path: t.outline, fill: t.style.fill, stroke: t.style.stroke), in: ctx)
            case .image(let i):
                if let image = assets?.image(for: i.assetID) {
                    // The context is y-down, so flip once around the image's height to draw it upright.
                    ctx.translateBy(x: 0, y: CGFloat(i.size.height))
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: i.size.width, height: i.size.height))
                }
            }

            if needsLayer { ctx.endTransparencyLayer() }
            ctx.restoreGState()
        }
    }

    private static func drawShape(_ s: ShapeContent, in ctx: CGContext) {
        let path = cgPath(s.path)
        if let fill = s.fill {
            ctx.addPath(path)
            ctx.setFillColor(cgColor(fill))
            ctx.fillPath(using: .winding)
        }
        if let stroke = s.stroke, stroke.width > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(cgColor(stroke.color))
            ctx.setLineWidth(CGFloat(stroke.width))
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }
    }

    static func cgPath(_ p: PathData) -> CGPath {
        let path = CGMutablePath()
        for e in p.elements {
            switch e {
            case .move(let a): path.move(to: CGPoint(x: a.x, y: a.y))
            case .line(let a): path.addLine(to: CGPoint(x: a.x, y: a.y))
            case .cubic(let a, let b, let c):
                path.addCurve(to: CGPoint(x: c.x, y: c.y), control1: CGPoint(x: a.x, y: a.y), control2: CGPoint(x: b.x, y: b.y))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    static func cgBlend(_ m: BlendMode) -> CGBlendMode {
        switch m {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .difference: return .difference
        }
    }
}
#endif
