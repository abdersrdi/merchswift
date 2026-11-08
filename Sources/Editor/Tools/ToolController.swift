import CutLine
import DocumentModel
import Foundation

/// Turns pointer and keyboard input into edits. It knows nothing about views: the canvas passes it events in
/// millimetres and draws what `overlayItems()` returns. Every edit goes through the `DocumentStore`, so undo
/// works, and a whole drag is one undo step.
public final class ToolController {
    public let store: DocumentStore
    /// The canvas keeps this up to date; it sets tolerances and handle sizes in screen terms.
    public var viewport = Viewport()
    public var snapSettings = SnapSettings(threshold: 1.0)
    /// Called whenever the selection, the tool or the overlay changed, so the view can redraw.
    public var onChange: (() -> Void)?

    public internal(set) var selection: [UUID] = [] { didSet { if oldValue != selection { notify() } } }
    public var tool: Tool = .select {
        didSet {
            guard oldValue != tool else { return }
            cancelInteraction()
            // Leaving a tool abandons whatever it had in progress.
            pen = nil; penHover = nil; penEdit = nil; penEditLayer = nil
            notify()
        }
    }

    // Interaction state shared with the pen and action extensions.
    enum Interaction {
        case move(start: Point, baseline: Document, ids: [UUID], rect: Rect2, others: [Rect2])
        case resize(handle: SelectionHandle, baseline: Document, ids: [UUID], rect: Rect2)
        case rotate(baseline: Document, ids: [UUID], center: Point, startAngle: Double)
        case marquee(start: Point, additive: Bool, base: [UUID])
        case penDraw
        case penAnchor(index: Int, grab: Point)
        case penHandle(index: Int, side: PenPath.Side)
    }
    var interaction: Interaction?
    var interactionKey = ""
    var moved = false
    var pendingSingleSelect: UUID?

    public internal(set) var snapLines: [SnapLine] = []
    public internal(set) var marquee: Rect2?

    /// Lays text out. Set by the app (Core Text); without it the text tool does nothing.
    public var textShaper: TextShaping?
    /// The style new text starts with.
    public var newTextStyle = TextStyle()

    // Pen state.
    var pen: PenPath?
    var penHover: Point?
    var penEditLayer: UUID?
    var penEdit: PenPath?

    private var observerToken: UUID?

    public init(store: DocumentStore) {
        self.store = store
        observerToken = store.observe { [weak self] in self?.documentChanged() }
    }

    deinit { if let t = observerToken { store.removeObserver(t) } }

    var document: Document { store.document }

    private var observers: [UUID: () -> Void] = [:]

    /// Registers another listener for selection, tool and overlay changes. Returns a token for `removeObserver`.
    @discardableResult
    public func observe(_ listener: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = listener
        return id
    }

    public func removeObserver(_ token: UUID) { observers[token] = nil }

    func notify() {
        onChange?()
        for l in observers.values { l() }
    }

    private func documentChanged() {
        // Undo or a delete can remove selected layers.
        let alive = selection.filter { document.layer(id: $0) != nil }
        if alive != selection { selection = alive } else { notify() }
        if let id = penEditLayer, document.layer(id: id) == nil { penEditLayer = nil; penEdit = nil }
    }

    // MARK: Geometry helpers

    /// A distance of `points` screen points, in millimetres.
    func mm(_ points: Double) -> Double { points / max(viewport.zoom, 1e-9) }

    public var selectionBounds: Rect2? {
        var out: Rect2?
        for id in selection {
            guard let b = document.worldBounds(of: id) else { continue }
            out = out.map { $0.union(b) } ?? b
        }
        return out
    }

    public func handlePositions() -> [(SelectionHandle, Point)] {
        guard let r = selectionBounds else { return [] }
        let rotateOffset = mm(26)
        return [
            (.topLeft, Point(r.minX, r.minY)), (.top, Point(r.midX, r.minY)), (.topRight, Point(r.maxX, r.minY)),
            (.right, Point(r.maxX, r.midY)), (.bottomRight, Point(r.maxX, r.maxY)), (.bottom, Point(r.midX, r.maxY)),
            (.bottomLeft, Point(r.minX, r.maxY)), (.left, Point(r.minX, r.midY)),
            (.rotate, Point(r.midX, r.minY - rotateOffset)),
        ]
    }

    func handleHit(at p: Point) -> SelectionHandle? {
        let tolerance = mm(11)
        var best: (Double, SelectionHandle)?
        for (h, pos) in handlePositions() {
            let d = (pos - p).length
            if d <= tolerance, best == nil || d < best!.0 { best = (d, h) }
        }
        return best?.1
    }

    func rootAncestor(of id: UUID) -> UUID? {
        for root in document.layers {
            if root.id == id || containsLayer(root, id) { return root.id }
        }
        return nil
    }

    private func containsLayer(_ l: Layer, _ id: UUID) -> Bool {
        l.children.contains { $0.id == id || containsLayer($0, id) }
    }

    // MARK: Pointer input

    public func pointerDown(_ e: PointerEvent) {
        switch tool {
        case .select: selectDown(e)
        case .pen: penDown(e)
        case .text: textDown(e)
        }
        notify()
    }

    public func pointerDragged(_ e: PointerEvent) {
        switch tool {
        case .select: selectDragged(e)
        case .pen: penDragged(e)
        case .text: break
        }
        notify()
    }

    public func pointerUp(_ e: PointerEvent) {
        switch tool {
        case .select: selectUp(e)
        case .pen: penUp(e)
        case .text: break
        }
        interaction = nil
        snapLines = []
        marquee = nil
        notify()
    }

    /// Mouse hover, for the pen's rubber band.
    public func pointerMoved(_ e: PointerEvent) {
        if tool == .pen, pen != nil { penHover = e.canvas; notify() }
    }

    /// A second finger or an interruption: abandons the drag and puts everything back as it was before it started.
    public func cancelInteraction() {
        switch interaction {
        case .move(_, let baseline, _, _, _), .resize(_, let baseline, _, _), .rotate(let baseline, _, _, _):
            _ = baseline
            if moved { store.revertLastChange() }
        default: break
        }
        interaction = nil
        snapLines = []
        marquee = nil
        moved = false
        notify()
    }

    func beginInteraction() {
        interactionKey = UUID().uuidString
        moved = false
    }

    // MARK: Select tool

    private func selectDown(_ e: PointerEvent) {
        let doc = document
        pendingSingleSelect = nil

        if !selection.isEmpty, let handle = handleHit(at: e.canvas), let rect = selectionBounds {
            beginInteraction()
            if handle == .rotate {
                let c = rect.center
                interaction = .rotate(baseline: doc, ids: selection, center: c,
                                      startAngle: atan2(e.canvas.y - c.y, e.canvas.x - c.x))
            } else {
                interaction = .resize(handle: handle, baseline: doc, ids: selection, rect: rect)
            }
            return
        }

        let hit = doc.hitTest(e.canvas, tolerance: mm(4)).flatMap { rootAncestor(of: $0) }
        if let hit {
            if e.modifiers.contains(.shift) {
                if let i = selection.firstIndex(of: hit) { selection.remove(at: i); return }
                selection.append(hit)
            } else if !selection.contains(hit) {
                selection = [hit]
            } else if selection.count > 1 {
                pendingSingleSelect = hit          // becomes the only selection if this turns out to be a click
            }
            beginMove(from: e.canvas)
        } else {
            beginInteraction()
            let additive = e.modifiers.contains(.shift)
            let base = additive ? selection : []
            if !additive { selection = [] }
            interaction = .marquee(start: e.canvas, additive: additive, base: base)
        }
    }

    private func beginMove(from p: Point) {
        guard let rect = selectionBounds else { return }
        beginInteraction()
        let others = document.layers.filter { $0.isVisible && !selection.contains($0.id) }
            .compactMap { document.worldBounds(of: $0.id) }
        interaction = .move(start: p, baseline: document, ids: selection, rect: rect, others: others)
    }

    private func selectDragged(_ e: PointerEvent) {
        guard let interaction else { return }
        switch interaction {
        case .move(let start, let baseline, let ids, let rect, let others):
            var d = e.canvas - start
            if !moved && d.length < mm(3) { return }          // a click, not a drag
            moved = true
            pendingSingleSelect = nil
            if e.modifiers.contains(.shift) { if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 } }
            snapLines = []
            if !e.modifiers.contains(.command) {
                var settings = snapSettings
                settings.threshold = mm(6)
                let r = Snapper.snap(moving: rect.offsetBy(dx: d.x, dy: d.y), others: others, document: baseline, settings: settings)
                d = d + r.delta
                snapLines = r.lines
            }
            d = Point(UnitConverter.snapToPrecision(d.x), UnitConverter.snapToPrecision(d.y))
            let key = interactionKey
            store.perform("Move", coalesceKey: key, window: .infinity) { doc in
                doc = baseline
                doc.translate(ids, by: ids.map { _ in d })
            }

        case .resize(let handle, let baseline, let ids, let rect):
            moved = true
            let t = resizeTransform(handle: handle, rect: rect, to: e.canvas, modifiers: e.modifiers)
            let key = interactionKey
            store.perform("Resize", coalesceKey: key, window: .infinity) { doc in
                doc = baseline
                for id in ids { doc.apply(canvasTransform: t, to: id) }
            }

        case .rotate(let baseline, let ids, let center, let startAngle):
            moved = true
            var delta = atan2(e.canvas.y - center.y, e.canvas.x - center.x) - startAngle
            if e.modifiers.contains(.shift) { let step = Double.pi / 12; delta = (delta / step).rounded() * step }
            let t = Transform2D.translation(-center.x, -center.y).then(.rotation(delta)).then(.translation(center.x, center.y))
            let key = interactionKey
            store.perform("Rotate", coalesceKey: key, window: .infinity) { doc in
                doc = baseline
                for id in ids { doc.apply(canvasTransform: t, to: id) }
            }

        case .marquee(let start, let additive, let base):
            let r = Rect2(x: min(start.x, e.canvas.x), y: min(start.y, e.canvas.y),
                          width: abs(e.canvas.x - start.x), height: abs(e.canvas.y - start.y))
            marquee = r
            var picked = additive ? base : []
            for root in document.layers where root.isVisible && !root.isLocked {
                if let b = document.worldBounds(of: root.id), b.intersects(r), !picked.contains(root.id) { picked.append(root.id) }
            }
            selection = picked

        default: break
        }
    }

    private func selectUp(_ e: PointerEvent) {
        if case .move? = interaction, !moved, let only = pendingSingleSelect { selection = [only] }
        pendingSingleSelect = nil
        moved = false
    }

    /// The scale about the opposite handle (or the centre with Option) that brings `handle` to `p`.
    func resizeTransform(handle: SelectionHandle, rect r: Rect2, to p: Point, modifiers: Modifiers) -> Transform2D {
        let hx: Double, hy: Double
        switch handle {
        case .topLeft: (hx, hy) = (r.minX, r.minY)
        case .top: (hx, hy) = (r.midX, r.minY)
        case .topRight: (hx, hy) = (r.maxX, r.minY)
        case .right: (hx, hy) = (r.maxX, r.midY)
        case .bottomRight: (hx, hy) = (r.maxX, r.maxY)
        case .bottom: (hx, hy) = (r.midX, r.maxY)
        case .bottomLeft: (hx, hy) = (r.minX, r.maxY)
        case .left: (hx, hy) = (r.minX, r.midY)
        case .rotate: return .identity
        }
        let anchorX: Double, anchorY: Double
        if modifiers.contains(.option) { (anchorX, anchorY) = (r.midX, r.midY) } else { (anchorX, anchorY) = (2 * r.midX - hx, 2 * r.midY - hy) }

        let changesX = handle != .top && handle != .bottom
        let changesY = handle != .left && handle != .right
        var sx = 1.0, sy = 1.0
        if changesX, abs(hx - anchorX) > 1e-9 { sx = (p.x - anchorX) / (hx - anchorX) }
        if changesY, abs(hy - anchorY) > 1e-9 { sy = (p.y - anchorY) / (hy - anchorY) }
        let corner = changesX && changesY
        if modifiers.contains(.shift) && corner {
            let m = max(abs(sx), abs(sy))
            sx = sx < 0 ? -m : m
            sy = sy < 0 ? -m : m
        } else if modifiers.contains(.shift) {
            // An edge handle with Shift scales both ways, keeping proportions.
            if !changesX { sx = sy } else if !changesY { sy = sx }
        }
        func clamp(_ s: Double) -> Double { abs(s) < 1e-3 ? (s < 0 ? -1e-3 : 1e-3) : s }
        sx = clamp(sx); sy = clamp(sy)
        return Transform2D.translation(-anchorX, -anchorY).then(.scale(sx, sy)).then(.translation(anchorX, anchorY))
    }
}
