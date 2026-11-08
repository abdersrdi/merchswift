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

/// The editing canvas: a Metal view that shows the document's tiles and the tool overlay.
///
/// Navigation: pinch and two-finger pan on iOS; scroll, command-scroll and trackpad pinch on the Mac; double tap with
/// two fingers (or double click on empty space) fits the canvas. One finger, the Pencil or the mouse drives the
/// current tool, and a second finger landing cancels that edit so a pinch never moves a layer.
public final class CanvasMTKView: MTKView {
    public private(set) var viewport = Viewport() {
        didSet { tools?.viewport = viewport }
    }
    public var onStats: ((CanvasStats) -> Void)?
    /// When false, a finger only navigates and the Pencil or a mouse draws.
    public var fingerDrivesTools = true

    private var commandQueue: MTLCommandQueue?
    private var compositor: CanvasCompositor?
    private var overlay: OverlayRenderer?
    private var cache: TileCache?
    private(set) var tools: ToolController?
    private var store: DocumentStore? { tools?.store }
    private var needsInitialFit = true
    private var lastFrameTime: CFTimeInterval = 0
    private var smoothedFPS = 0.0
    private weak var assets: AssetProvider?
    private var tokens: [UUID] = []

    public init?(tools: ToolController, assets: AssetProvider?) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        super.init(frame: .zero, device: device)
        self.tools = tools
        self.assets = assets
        commandQueue = device.makeCommandQueue()
        colorPixelFormat = .bgra8Unorm
        clearColor = CanvasCompositor.backgroundColor
        enableSetNeedsDisplay = true
        isPaused = true
        framebufferOnly = true
        preferredFramesPerSecond = 120
        let samples = device.supportsTextureSampleCount(4) ? 4 : 1
        sampleCount = samples

        compositor = CanvasCompositor(device: device, colorPixelFormat: colorPixelFormat, sampleCount: samples)
        overlay = OverlayRenderer(device: device, colorPixelFormat: colorPixelFormat, sampleCount: samples)
        let cache = TileCache(device: device)
        cache.onTileReady = { [weak self] in self?.redraw() }
        cache.setDocument(tools.store.document, assets: assets)
        self.cache = cache
        tools.viewport = viewport

        tokens.append(tools.store.observe { [weak self] in
            guard let self, let store = self.store else { return }
            self.cache?.setDocument(store.document, assets: self.assets)
            self.redraw()
        })
        tokens.append(tools.observe { [weak self] in self?.redraw() })
        installGestures()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let tools {
            for t in tokens { tools.store.removeObserver(t); tools.removeObserver(t) }
        }
    }

    // MARK: Public controls

    public func fit() {
        guard let doc = store?.document else { return }
        viewport.viewSize = currentViewSize
        viewport.fit(doc.canvas)
        redraw()
    }

    /// Zooms to 100%: one millimetre of the design is `pointsPerMM` points on screen (72 points per inch by default).
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
        guard let store, let tools, let compositor, let cache, let commandQueue, let device,
              bounds.width > 1, bounds.height > 1,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }

        let size = currentViewSize
        if size != viewport.viewSize { viewport.viewSize = size }
        if needsInitialFit { needsInitialFit = false; viewport.fit(store.document.canvas) }

        guard let cb = commandQueue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let frame = compositor.encode(into: enc, document: store.document, viewport: viewport, scale: backingScale, cache: cache)
        overlay?.encode(into: enc, items: tools.overlayItems(), viewport: viewport, device: device)
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

    // MARK: Tool events

    private func event(atScreen p: CGPoint, modifiers: Modifiers, kind: PointerKind, clicks: Int) -> PointerEvent {
        let screen = Point(Double(p.x), Double(p.y))
        return PointerEvent(canvas: viewport.screenToCanvas(screen), screen: screen, modifiers: modifiers, kind: kind, clickCount: clicks)
    }

    #if canImport(UIKit)
    private var activeTouch: UITouch?
    private var suppressTouches = false
    private var lastPan = CGPoint.zero

    public override var canBecomeFirstResponder: Bool { true }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    private func installGestures() {
        isMultipleTouchEnabled = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        double.numberOfTouchesRequired = 2
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        for g in [pinch, pan, double, hover] as [UIGestureRecognizer] { addGestureRecognizer(g) }
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

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .changed || g.state == .began else { return }
        tools?.pointerMoved(event(atScreen: g.location(in: self), modifiers: [], kind: .pencil, clicks: 0))
    }

    private func modifiers(_ event: UIEvent?) -> Modifiers {
        var m: Modifiers = []
        guard let f = event?.modifierFlags else { return m }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.alternate) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.control) { m.insert(.control) }
        return m
    }

    private func pointer(_ t: UITouch, _ e: UIEvent?) -> PointerEvent {
        event(atScreen: t.location(in: self), modifiers: modifiers(e), kind: t.type == .pencil ? .pencil : .touch, clicks: max(t.tapCount, 1))
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.count ?? 1) > 1 {
            // A second finger means navigation: undo what the first one started.
            tools?.cancelInteraction()
            activeTouch = nil
            suppressTouches = true
            return
        }
        guard !suppressTouches, activeTouch == nil, let t = touches.first else { return }
        if t.type == .direct && !fingerDrivesTools { return }
        activeTouch = t
        tools?.pointerDown(pointer(t, event))
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        tools?.pointerDragged(pointer(t, event))
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = activeTouch, touches.contains(t) {
            tools?.pointerUp(pointer(t, event))
            activeTouch = nil
        }
        if event?.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { suppressTouches = false }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = activeTouch, touches.contains(t) { tools?.cancelInteraction(); activeTouch = nil }
        if event?.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { suppressTouches = false }
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            var m: Modifiers = []
            if key.modifierFlags.contains(.shift) { m.insert(.shift) }
            if key.modifierFlags.contains(.alternate) { m.insert(.option) }
            if key.modifierFlags.contains(.command) { m.insert(.command) }
            let toolKey: ToolKey?
            switch key.keyCode {
            case .keyboardDeleteOrBackspace, .keyboardDeleteForward: toolKey = .delete
            case .keyboardEscape: toolKey = .escape
            case .keyboardReturnOrEnter: toolKey = .enter
            case .keyboardLeftArrow: toolKey = .arrow(dx: -1, dy: 0)
            case .keyboardRightArrow: toolKey = .arrow(dx: 1, dy: 0)
            case .keyboardUpArrow: toolKey = .arrow(dx: 0, dy: -1)
            case .keyboardDownArrow: toolKey = .arrow(dx: 0, dy: 1)
            default:
                if let c = key.charactersIgnoringModifiers.first { toolKey = .character(c) } else { toolKey = nil }
            }
            if let toolKey, tools?.handleKey(toolKey, modifiers: m) == true { handled = true }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
    #else
    private func installGestures() {
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    private func modifiers(_ e: NSEvent) -> Modifiers {
        var m: Modifiers = []
        let f = e.modifierFlags
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.control) { m.insert(.control) }
        return m
    }

    private func pointer(_ e: NSEvent) -> PointerEvent {
        event(atScreen: convert(e.locationInWindow, from: nil), modifiers: modifiers(e), kind: .mouse, clicks: e.clickCount)
    }

    public override func scrollWheel(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let anchor = Point(Double(loc.x), Double(loc.y))
        if event.modifierFlags.contains(.command) {
            zoom(by: exp(Double(event.scrollingDeltaY) * 0.01), around: anchor)
        } else {
            let k = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
            pan(byScreen: Double(event.scrollingDeltaX) * k, Double(event.scrollingDeltaY) * k)
        }
    }

    public override func magnify(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + Double(event.magnification), around: Point(Double(loc.x), Double(loc.y)))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        tools?.pointerDown(pointer(event))
    }

    public override func mouseDragged(with event: NSEvent) { tools?.pointerDragged(pointer(event)) }
    public override func mouseUp(with event: NSEvent) { tools?.pointerUp(pointer(event)) }
    public override func mouseMoved(with event: NSEvent) { tools?.pointerMoved(pointer(event)) }

    public override func keyDown(with event: NSEvent) {
        var key: ToolKey?
        switch event.keyCode {
        case 51, 117: key = .delete
        case 53: key = .escape
        case 36, 76: key = .enter
        case 123: key = .arrow(dx: -1, dy: 0)
        case 124: key = .arrow(dx: 1, dy: 0)
        case 126: key = .arrow(dx: 0, dy: -1)
        case 125: key = .arrow(dx: 0, dy: 1)
        default:
            if let c = event.charactersIgnoringModifiers?.first { key = .character(c) }
        }
        if let key, tools?.handleKey(key, modifiers: modifiers(event)) == true { return }
        super.keyDown(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let c = event.charactersIgnoringModifiers?.first else {
            return super.performKeyEquivalent(with: event)
        }
        return tools?.handleKey(.character(c), modifiers: modifiers(event)) ?? false
    }
    #endif
}

#if canImport(UIKit)
extension CanvasMTKView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
#endif
