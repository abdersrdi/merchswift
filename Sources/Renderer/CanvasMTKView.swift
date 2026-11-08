#if canImport(MetalKit) && (canImport(UIKit) || canImport(AppKit))
import CutLine
import DocumentModel
import Editor
import Foundation
import MetalKit
import QuartzCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What the canvas reports after each frame, for an on-screen readout.
public struct CanvasStats: Equatable {
    public var zoomPercent = 100
    public var frame = FrameStats()
    public var cachedTiles = 0
    public var pendingTiles = 0
    public var framesPerSecond = 0.0
    public init() {}
    public init(zoomPercent: Int, frame: FrameStats, cachedTiles: Int, pendingTiles: Int, framesPerSecond: Double) {
        self.zoomPercent = zoomPercent; self.frame = frame; self.cachedTiles = cachedTiles
        self.pendingTiles = pendingTiles; self.framesPerSecond = framesPerSecond
    }
}

/// The editing canvas: a Metal view that shows the document's tiles, with pinch and two-finger pan on iOS,
/// and scroll, command-scroll and trackpad pinch on the Mac. Double tap (or double click) fits the canvas.
public final class CanvasMTKView: MTKView {
    public private(set) var viewport = Viewport()
    public var onStats: ((CanvasStats) -> Void)?

    private var commandQueue: MTLCommandQueue?
    private var compositor: CanvasCompositor?
    private var cache: TileCache?
    private var store: DocumentStore?
    private var needsInitialFit = true
    private var lastFrameTime: CFTimeInterval = 0
    private var smoothedFPS = 0.0

    public init?(store: DocumentStore, assets: AssetProvider?) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        super.init(frame: .zero, device: device)
        self.store = store
        commandQueue = device.makeCommandQueue()
        colorPixelFormat = .bgra8Unorm
        clearColor = CanvasCompositor.backgroundColor
        enableSetNeedsDisplay = true
        isPaused = true
        framebufferOnly = true
        preferredFramesPerSecond = 120

        compositor = CanvasCompositor(device: device, colorPixelFormat: colorPixelFormat)
        let cache = TileCache(device: device)
        cache.onTileReady = { [weak self] in self?.redraw() }
        cache.setDocument(store.document, assets: assets)
        self.cache = cache
        self.assets = assets

        store.onChange = { [weak self] in
            guard let self, let store = self.store else { return }
            self.cache?.setDocument(store.document, assets: self.assets)
            self.redraw()
        }
        installGestures()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    private weak var assets: AssetProvider?

    // MARK: Public controls

    public func fit() {
        guard let doc = store?.document else { return }
        viewport.viewSize = currentViewSize
        viewport.fit(doc.canvas)
        redraw()
    }

    /// Zooms to 100%: one millimetre of the design is 1 mm on screen, using 96 points per inch... roughly.
    /// `pointsPerMM` is the on-screen size of a millimetre at 100%.
    public func zoomToActualSize(pointsPerMM: Double = 72.0 / 25.4) {
        let c = Point(viewport.viewSize.width / 2, viewport.viewSize.height / 2)
        viewport.zoom(by: pointsPerMM / viewport.zoom, around: c)
        redraw()
    }

    public func zoom(by factor: Double, around anchor: Point? = nil) {
        let a = anchor ?? Point(viewport.viewSize.width / 2, viewport.viewSize.height / 2)
        viewport.zoom(by: factor, around: a)
        clampAndRedraw()
    }

    public func pan(byScreen dx: Double, _ dy: Double) {
        viewport.pan(byScreen: dx, dy)
        clampAndRedraw()
    }

    public func redraw() {
        #if canImport(UIKit)
        setNeedsDisplay()
        #else
        needsDisplay = true
        #endif
    }

    private func clampAndRedraw() {
        if let doc = store?.document { viewport.clamp(to: doc.canvas) }
        redraw()
    }

    // MARK: Drawing

    private var currentViewSize: Size2 { Size2(Double(bounds.width), Double(bounds.height)) }

    private var backingScale: Double {
        #if canImport(UIKit)
        return Double(contentScaleFactor)
        #else
        return Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        #endif
    }

    public override func draw(_ rect: CGRect) {
        guard let store, let compositor, let cache, let commandQueue,
              bounds.width > 1, bounds.height > 1,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }

        viewport.viewSize = currentViewSize
        if needsInitialFit { needsInitialFit = false; viewport.fit(store.document.canvas) }

        guard let cb = commandQueue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let frame = compositor.encode(into: enc, document: store.document, viewport: viewport, scale: backingScale, cache: cache)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        let now = CACurrentMediaTime()
        if lastFrameTime > 0, now - lastFrameTime < 1 {
            smoothedFPS = smoothedFPS == 0 ? 1 / (now - lastFrameTime) : smoothedFPS * 0.9 + 0.1 / (now - lastFrameTime)
        } else {
            smoothedFPS = 0
        }
        lastFrameTime = now

        if let onStats {
            let s = CanvasStats(zoomPercent: Int((viewport.zoom / (72.0 / 25.4) * 100).rounded()), frame: frame,
                                cachedTiles: cache.cachedCount, pendingTiles: cache.pendingCount, framesPerSecond: smoothedFPS)
            DispatchQueue.main.async { onStats(s) }
        }
    }

    // MARK: Gestures

    #if canImport(UIKit)
    private var lastPan = CGPoint.zero

    private func installGestures() {
        isMultipleTouchEnabled = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        double.numberOfTouchesRequired = 2
        for g in [pinch, pan, double] as [UIGestureRecognizer] { addGestureRecognizer(g) }
        pinch.delegate = self
        pan.delegate = self
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        let p = g.location(in: self)
        zoom(by: Double(g.scale), around: Point(Double(p.x), Double(p.y)))
        g.scale = 1
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        if g.state == .began { lastPan = .zero }
        pan(byScreen: Double(t.x - lastPan.x), Double(t.y - lastPan.y))
        lastPan = t
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) { fit() }
    #else
    private func installGestures() {}

    public override var acceptsFirstResponder: Bool { true }

    public override func scrollWheel(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let anchor = Point(Double(loc.x), Double(bounds.height - loc.y))
        if event.modifierFlags.contains(.command) {
            zoom(by: exp(Double(event.scrollingDeltaY) * 0.01), around: anchor)
        } else {
            let k = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
            pan(byScreen: Double(event.scrollingDeltaX) * k, Double(event.scrollingDeltaY) * k)
        }
    }

    public override func magnify(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + Double(event.magnification), around: Point(Double(loc.x), Double(bounds.height - loc.y)))
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { fit() }
    }
    #endif
}

#if canImport(UIKit)
extension CanvasMTKView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
#endif
