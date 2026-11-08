#if canImport(Metal) && canImport(CoreGraphics)
import CutLine
import DocumentModel
import Editor
import Foundation
import Metal
import simd

/// Draws the tool overlay (selection boxes, handles, guides, the pen path) on top of the canvas. Everything is built
/// on the CPU as triangles in screen points, so lines and handles keep their size at any zoom.
public final class OverlayRenderer {
    private let pipeline: MTLRenderPipelineState

    struct Vertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex { float2 position; float4 color; };
    struct VOut { float4 position [[position]]; float4 color; };

    vertex VOut overlay_vertex(uint vid [[vertex_id]], constant Vertex* verts [[buffer(0)]],
                               constant float2& viewSize [[buffer(1)]]) {
        Vertex v = verts[vid];
        VOut o;
        o.position = float4(v.position.x / viewSize.x * 2.0 - 1.0, 1.0 - v.position.y / viewSize.y * 2.0, 0.0, 1.0);
        o.color = v.color;
        return o;
    }

    fragment float4 overlay_fragment(VOut in [[stage_in]]) { return in.color; }
    """

    public init?(device: MTLDevice, colorPixelFormat: MTLPixelFormat, sampleCount: Int = 1) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vf = library.makeFunction(name: "overlay_vertex"),
              let ff = library.makeFunction(name: "overlay_fragment") else { return nil }
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
    }

    public func encode(into encoder: MTLRenderCommandEncoder, items: [OverlayItem], viewport: Viewport, device: MTLDevice) {
        guard !items.isEmpty else { return }
        var verts: [Vertex] = []
        for item in items { Self.append(item, viewport: viewport, to: &verts) }
        guard !verts.isEmpty else { return }

        // setVertexBytes is limited to 4 KB; a path with many segments is bigger, so use a buffer.
        guard let buffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Vertex>.stride,
                                             options: .storageModeShared) else { return }
        encoder.setRenderPipelineState(pipeline)
        var size = SIMD2<Float>(Float(viewport.viewSize.width), Float(viewport.viewSize.height))
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }

    // MARK: Geometry

    static func color(_ c: RGBA) -> SIMD4<Float> {
        SIMD4(Float(c.r * c.a), Float(c.g * c.a), Float(c.b * c.a), Float(c.a))
    }

    static func append(_ item: OverlayItem, viewport: Viewport, to out: inout [Vertex]) {
        func screen(_ p: Point) -> SIMD2<Float> {
            let s = viewport.canvasToScreen(p)
            return SIMD2(Float(s.x), Float(s.y))
        }
        switch item {
        case .rectFill(let r, let c):
            let a = screen(Point(r.minX, r.minY)), b = screen(Point(r.maxX, r.minY))
            let cc = screen(Point(r.maxX, r.maxY)), d = screen(Point(r.minX, r.maxY))
            quad(a, b, cc, d, color(c), &out)

        case .polyline(let pts, let closed, let c, let width, let dashed):
            let sp = pts.map(screen)
            let count = closed ? sp.count : sp.count - 1
            guard count >= 1 else { return }
            let col = color(c)
            var travelled: Float = 0
            for i in 0..<count {
                let p0 = sp[i], p1 = sp[(i + 1) % sp.count]
                if dashed {
                    travelled = dashedSegment(p0, p1, width: Float(width), color: col, travelled: travelled, &out)
                } else {
                    segment(p0, p1, width: Float(width), color: col, &out)
                }
            }

        case .marker(let p, let shape, let size, let fill, let stroke):
            let c = screen(p)
            let half = Float(size) / 2
            func outline(_ extra: Float, _ col: SIMD4<Float>) {
                switch shape {
                case .square:
                    let h = half + extra
                    quad(SIMD2(c.x - h, c.y - h), SIMD2(c.x + h, c.y - h), SIMD2(c.x + h, c.y + h), SIMD2(c.x - h, c.y + h), col, &out)
                case .diamond:
                    let h = (half + extra) * 1.25
                    quad(SIMD2(c.x, c.y - h), SIMD2(c.x + h, c.y), SIMD2(c.x, c.y + h), SIMD2(c.x - h, c.y), col, &out)
                case .circle:
                    let r = half + extra
                    let n = 14
                    for i in 0..<n {
                        let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
                        out.append(Vertex(position: c, color: col))
                        out.append(Vertex(position: SIMD2(c.x + cos(a0) * r, c.y + sin(a0) * r), color: col))
                        out.append(Vertex(position: SIMD2(c.x + cos(a1) * r, c.y + sin(a1) * r), color: col))
                    }
                }
            }
            outline(1.2, color(stroke))
            outline(0, color(fill))
        }
    }

    private static func quad(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>,
                             _ col: SIMD4<Float>, _ out: inout [Vertex]) {
        for p in [a, b, c, a, c, d] { out.append(Vertex(position: p, color: col)) }
    }

    private static func segment(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, width: Float, color: SIMD4<Float>, _ out: inout [Vertex]) {
        let d = p1 - p0
        let len = simd_length(d)
        guard len > 1e-4 else { return }
        let n = SIMD2<Float>(-d.y, d.x) / len * (width / 2)
        // Extend a little so consecutive segments overlap at joints.
        let e = d / len * (width / 2)
        quad(p0 - e + n, p1 + e + n, p1 + e - n, p0 - e - n, color, &out)
    }

    /// Dashes of 6 points with gaps of 4, continuing the pattern across segments.
    private static func dashedSegment(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, width: Float, color: SIMD4<Float>,
                                      travelled: Float, _ out: inout [Vertex]) -> Float {
        let d = p1 - p0
        let len = simd_length(d)
        guard len > 1e-4 else { return travelled }
        let dir = d / len
        let on: Float = 6, off: Float = 4, period = on + off
        var t: Float = 0
        while t < len {
            let phase = (travelled + t).truncatingRemainder(dividingBy: period)
            if phase < on {
                let run = min(on - phase, len - t)
                segment(p0 + dir * t, p0 + dir * (t + run), width: width, color: color, &out)
                t += run
            } else {
                t += period - phase
            }
        }
        return travelled + len
    }
}
#endif
