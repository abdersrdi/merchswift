import CutLine
import DocumentModel
import Foundation

/// Where the canvas sits on screen. `zoom` is screen points per millimetre; `origin` is the canvas
/// position (mm) shown at the top left corner of the view.
public struct Viewport: Equatable {
    public var zoom: Double
    public var origin: Point
    public var viewSize: Size2          // points

    public static let minZoom = 0.05    // 5 points per metre of... about 0.05 pt/mm, a 1 m canvas in 50 pt
    public static let maxZoom = 400.0   // 400 pt per mm, far past 600 DPI at any screen scale

    public init(zoom: Double = 1, origin: Point = Point(0, 0), viewSize: Size2 = Size2(800, 600)) {
        self.zoom = zoom; self.origin = origin; self.viewSize = viewSize
    }

    public func canvasToScreen(_ p: Point) -> Point { Point((p.x - origin.x) * zoom, (p.y - origin.y) * zoom) }
    public func screenToCanvas(_ p: Point) -> Point { Point(p.x / zoom + origin.x, p.y / zoom + origin.y) }

    public var visibleCanvasRect: Rect2 {
        Rect2(x: origin.x, y: origin.y, width: viewSize.width / zoom, height: viewSize.height / zoom)
    }

    /// Scrolls the canvas by a screen-space amount (a drag of +10 points moves the content 10 points).
    public mutating func pan(byScreen dx: Double, _ dy: Double) {
        origin = Point(origin.x - dx / zoom, origin.y - dy / zoom)
    }

    /// Zooms by `factor`, keeping the canvas point under `anchor` (screen points) fixed.
    public mutating func zoom(by factor: Double, around anchor: Point) {
        let before = screenToCanvas(anchor)
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        origin = Point(before.x - anchor.x / zoom, before.y - anchor.y / zoom)
    }

    /// Zooms so the whole `canvas` fits with `padding` points around it, centred.
    public mutating func fit(_ canvas: Rect2, padding: Double = 24) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        let availW = max(viewSize.width - 2 * padding, 1), availH = max(viewSize.height - 2 * padding, 1)
        zoom = min(max(min(availW / canvas.width, availH / canvas.height), Self.minZoom), Self.maxZoom)
        origin = Point(canvas.midX - viewSize.width / zoom / 2, canvas.midY - viewSize.height / zoom / 2)
    }

    /// Keeps at least `margin` points of the canvas on screen, so it can never be scrolled out of reach.
    public mutating func clamp(to canvas: Rect2, margin: Double = 80) {
        let m = margin / zoom
        let w = viewSize.width / zoom, h = viewSize.height / zoom
        origin.x = min(max(origin.x, canvas.minX - w + m), canvas.maxX - m)
        origin.y = min(max(origin.y, canvas.minY - h + m), canvas.maxY - m)
    }
}
