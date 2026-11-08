#if canImport(Metal) && canImport(CoreGraphics)
import CutLine
import DocumentModel
import Editor
import Foundation
import Metal
import simd

public struct FrameStats: Equatable {
    public var level = 0
    public var tilesDrawn = 0
    public var tilesMissing = 0
    public var backdropTiles = 0
    public var encodeMilliseconds = 0.0
    public init() {}
}

/// Draws the visible tiles of a document with Metal: paper and shadow, then lower and higher density tiles that are
/// already cached as a stand-in, then the tiles at the right density on top.
public final class CanvasCompositor {
    public let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    struct Uniforms {
        var viewSize: SIMD2<Float>
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var color: SIMD4<Float>
        var mode: UInt32
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewSize;
        float2 origin;
        float2 size;
        float4 color;
        uint mode;
    };
    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut canvas_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
        const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        float2 c = corners[vid];
        float2 p = u.origin + c * u.size;
        VOut o;
        o.position = float4(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0, 0.0, 1.0);
        o.uv = c;
        return o;
    }

    fragment float4 canvas_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                    texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        if (u.mode == 0) { return u.color; }
        float4 c = tex.sample(smp, in.uv);
        // Interleaved gradient noise, about half a code value, so 16-bit tiles shown in 8 bits do not band.
        float n = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
        c.rgb += (n - 0.5) / 255.0 * c.a;
        return c;
    }
    """

    public init?(device: MTLDevice, colorPixelFormat: MTLPixelFormat, sampleCount: Int = 1) {
        self.device = device
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vf = library.makeFunction(name: "canvas_vertex"),
              let ff = library.makeFunction(name: "canvas_fragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.rasterSampleCount = sampleCount
        let a = d.colorAttachments[0]!
        a.pixelFormat = colorPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipeline = p
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sd) else { return nil }
        sampler = s
    }

    /// Colour behind the canvas (premultiplied by the clear colour of the pass).
    public static let backgroundColor = MTLClearColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1)

    /// Encodes one frame. `scale` is the number of device pixels per point.
    @discardableResult
    public func encode(into encoder: MTLRenderCommandEncoder, document: Document, viewport: Viewport,
                       scale: Double, cache: TileCache) -> FrameStats {
        let started = DispatchTime.now().uptimeNanoseconds
        var stats = FrameStats()
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        let viewSize = SIMD2<Float>(Float(viewport.viewSize.width), Float(viewport.viewSize.height))

        // Screen rectangle of a canvas rectangle, with edges rounded to whole device pixels so tiles never leave seams.
        func screenRect(_ r: Rect2) -> (SIMD2<Float>, SIMD2<Float>) {
            func snap(_ v: Double) -> Double { (v * scale).rounded() / scale }
            let tl = viewport.canvasToScreen(Point(r.minX, r.minY)), br = viewport.canvasToScreen(Point(r.maxX, r.maxY))
            let x0 = snap(tl.x), y0 = snap(tl.y), x1 = snap(br.x), y1 = snap(br.y)
            return (SIMD2(Float(x0), Float(y0)), SIMD2(Float(x1 - x0), Float(y1 - y0)))
        }
        func solid(_ r: Rect2, _ color: SIMD4<Float>) {
            let (o, s) = screenRect(r)
            var u = Uniforms(viewSize: viewSize, origin: o, size: s, color: color, mode: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        func textured(_ key: TileKey, _ texture: MTLTexture) {
            let (o, s) = screenRect(TileGrid.rect(of: key))
            var u = Uniforms(viewSize: viewSize, origin: o, size: s, color: .zero, mode: 1)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Paper with a soft shadow made of a few widening translucent rectangles.
        let canvas = document.canvas
        let spread = 6.0 / viewport.zoom
        for i in (1...4).reversed() {
            let g = spread * Double(i) / 4
            let r = Rect2(x: canvas.minX - g, y: canvas.minY - g + spread / 3, width: canvas.width + 2 * g, height: canvas.height + 2 * g)
            solid(r, SIMD4<Float>(0, 0, 0, 0.07))
        }
        solid(canvas, SIMD4<Float>(1, 1, 1, 1))

        let level = TileGrid.level(screenPixelsPerMM: viewport.zoom * scale, documentDPI: document.dpi)
        stats.level = level
        let visible = viewport.visibleCanvasRect

        // Stand-ins from other densities, so zooming never shows blank paper while tiles render.
        for delta in [-3, -2, -1, 2, 1] {
            let other = level + delta
            if other < TileGrid.minLevel { continue }
            for key in TileGrid.visibleTiles(visible: visible, canvas: canvas, level: other) {
                if let t = cache.peek(key) { textured(key, t); stats.backdropTiles += 1 }
            }
        }

        for key in TileGrid.visibleTiles(visible: visible, canvas: canvas, level: level) {
            if let t = cache.texture(for: key) { textured(key, t); stats.tilesDrawn += 1 } else { stats.tilesMissing += 1 }
        }
        stats.encodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return stats
    }

    /// Draws one frame into `target` and waits for it. For tests, previews and exports; the canvas view
    /// uses `encode` inside its own pass.
    public func render(document: Document, viewport: Viewport, scale: Double, cache: TileCache,
                       into target: MTLTexture, commandQueue: MTLCommandQueue) -> FrameStats? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = Self.backgroundColor
        pass.colorAttachments[0].storeAction = .store
        guard let cb = commandQueue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let stats = encode(into: enc, document: document, viewport: viewport, scale: scale, cache: cache)
        enc.endEncoding()
        #if os(macOS)
        if target.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        #endif
        cb.commit()
        cb.waitUntilCompleted()
        return stats
    }
}
#endif
