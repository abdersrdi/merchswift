import CutLine
import DocumentModel
import Foundation

extension ToolController {
    // MARK: Keyboard

    /// Returns true if the key was used.
    @discardableResult
    public func handleKey(_ key: ToolKey, modifiers: Modifiers = []) -> Bool {
        switch key {
        case .escape:
            if pen != nil { pen = nil; penHover = nil; notify(); return true }
            if interaction != nil { cancelInteraction(); return true }
            if !selection.isEmpty { selection = []; return true }
            return false
        case .enter:
            if pen != nil { finishPath(); return true }
            return false
        case .delete:
            if tool == .pen, penDeleteKey() { notify(); return true }
            return deleteSelection()
        case .arrow(let dx, let dy):
            let step = modifiers.contains(.shift) ? 1.0 : (modifiers.contains(.option) ? 0.01 : 0.1)
            return nudge(dx: Double(dx) * step, dy: Double(dy) * step)
        case .character(let c):
            return handleShortcut(c, modifiers: modifiers)
        }
    }

    private func handleShortcut(_ c: Character, modifiers m: Modifiers) -> Bool {
        let key = Character(String(c).lowercased())
        if m.contains(.command) {
            switch key {
            case "z": if m.contains(.shift) { store.redo() } else { store.undo() }; return true
            case "y": store.redo(); return true
            case "a": selectAll(); return true
            case "d": duplicateSelection(); return true
            case "g": if m.contains(.shift) { ungroupSelection() } else { groupSelection() }; return true
            default: return false
            }
        }
        switch key {
        case "v": tool = .select; return true
        case "p": tool = .pen; return true
        default: return false
        }
    }

    // MARK: Selection and editing actions

    public func selectAll() {
        selection = document.layers.filter { $0.isVisible && !$0.isLocked }.map { $0.id }
    }

    public func select(_ ids: [UUID]) {
        selection = ids.filter { document.layer(id: $0) != nil }
    }

    @discardableResult
    public func deleteSelection() -> Bool {
        let ids = selection
        guard !ids.isEmpty else { return false }
        store.perform(ids.count == 1 ? "Delete layer" : "Delete layers") { doc in
            for id in ids { doc.remove(id: id) }
        }
        selection = []
        return true
    }

    @discardableResult
    public func nudge(dx: Double, dy: Double) -> Bool {
        let ids = selection.filter { document.layer(id: $0)?.isLocked == false }
        guard !ids.isEmpty else { return false }
        store.perform("Nudge", coalesceKey: "nudge-\(ids.map { $0.uuidString }.joined())") { doc in
            doc.translate(ids, by: ids.map { _ in Point(dx, dy) })
        }
        return true
    }

    public func duplicateSelection(offset: Double = 5) {
        let ids = selection
        guard !ids.isEmpty else { return }
        var created: [UUID] = []
        store.perform("Duplicate") { doc in
            for id in ids {
                guard let layer = doc.layer(id: id), let root = doc.layers.firstIndex(where: { $0.id == id }) else { continue }
                var copy = Self.copyWithNewIDs(layer)
                copy.name = layer.name + " copy"
                copy.transform = copy.transform.then(.translation(offset, offset))
                doc.insert(copy, at: root + 1)
                created.append(copy.id)
            }
        }
        if !created.isEmpty { selection = created }
    }

    static func copyWithNewIDs(_ l: Layer) -> Layer {
        var c = l
        c.id = UUID()
        if case .group(let kids) = l.content { c.content = .group(kids.map { copyWithNewIDs($0) }) }
        return c
    }

    public func groupSelection() {
        let ids = selection
        guard ids.count >= 2 else { return }
        var gid: UUID?
        store.perform("Group") { gid = $0.group(ids: ids) }
        if let gid { selection = [gid] }
    }

    public func ungroupSelection() {
        let groups = selection.filter { if case .group? = document.layer(id: $0)?.content { return true } else { return false } }
        guard !groups.isEmpty else { return }
        var children: [UUID] = []
        store.perform("Ungroup") { doc in
            for g in groups {
                children += doc.layer(id: g)?.children.map { $0.id } ?? []
                doc.ungroup(id: g)
            }
        }
        selection = children
    }

    public var canCombine: Bool {
        selection.count >= 2 && selection.allSatisfy {
            if case .shape? = document.layer(id: $0)?.content { return true } else { return false }
        }
    }

    public func combineSelection(_ op: BooleanOperation) {
        guard canCombine else { return }
        let ids = selection
        var result: UUID?
        store.perform("Combine") { result = $0.combine(ids, op) }
        if let result { selection = [result] }
    }

    /// Sets the selection's position and size on the canvas, as typed in the inspector (millimetres).
    public func setFrame(_ rect: Rect2) {
        guard selection.count == 1, let id = selection.first else { return }
        store.perform("Set size and position") { _ = $0.setFrame(of: id, to: rect) }
    }

    public func setOpacity(_ value: Double) {
        let ids = selection
        guard !ids.isEmpty else { return }
        let v = min(max(value, 0), 1)
        store.perform("Opacity", coalesceKey: "opacity-\(ids.map { $0.uuidString }.joined())") { doc in
            for id in ids { doc.update(id: id) { $0.opacity = v } }
        }
    }

    public func setBlendMode(_ mode: BlendMode) {
        let ids = selection
        guard !ids.isEmpty else { return }
        store.perform("Blend mode") { doc in for id in ids { doc.update(id: id) { $0.blendMode = mode } } }
    }

    public func setLocked(_ locked: Bool) {
        let ids = selection
        store.perform(locked ? "Lock" : "Unlock") { doc in for id in ids { doc.update(id: id) { $0.isLocked = locked } } }
    }

    // MARK: Overlay

    /// Everything the canvas should draw on top of the design for the current tool and state.
    public func overlayItems() -> [OverlayItem] {
        var items: [OverlayItem] = []
        let accent = OverlayColors.accent

        // Smart guides while moving.
        let visible = viewport.visibleCanvasRect
        for line in snapLines {
            let pts: [Point] = line.axis == .vertical
                ? [Point(line.position, visible.minY), Point(line.position, visible.maxY)]
                : [Point(visible.minX, line.position), Point(visible.maxX, line.position)]
            items.append(.polyline(pts, closed: false, color: OverlayColors.guide, width: 1, dashed: false))
        }

        if let m = marquee {
            items.append(.rectFill(m, color: OverlayColors.accentSoft))
            items.append(.polyline(rectPoints(m), closed: true, color: accent, width: 1, dashed: true))
        }

        if tool == .select || penEdit == nil {
            for id in selection {
                guard let b = document.worldBounds(of: id) else { continue }
                items.append(.polyline(rectPoints(b), closed: true, color: accent, width: 1, dashed: selection.count > 1))
            }
        }

        if tool == .select, let r = selectionBounds, !selection.isEmpty {
            if selection.count > 1 { items.append(.polyline(rectPoints(r), closed: true, color: accent, width: 1, dashed: false)) }
            let handles = handlePositions()
            if let top = handles.first(where: { $0.0 == .top })?.1, let rot = handles.first(where: { $0.0 == .rotate })?.1 {
                items.append(.polyline([top, rot], closed: false, color: accent, width: 1, dashed: false))
            }
            for (h, p) in handles {
                items.append(.marker(p, shape: h == .rotate ? .circle : .square, size: 8, fill: OverlayColors.handleFill, stroke: accent))
            }
        }

        if tool == .pen { items += penOverlay() }
        return items
    }

    private func rectPoints(_ r: Rect2) -> [Point] {
        [Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.maxX, r.maxY), Point(r.minX, r.maxY)]
    }

    private func penOverlay() -> [OverlayItem] {
        var items: [OverlayItem] = []
        let ink = OverlayColors.pen, accent = OverlayColors.accent

        func drawAnchors(_ path: PenPath, transform: Transform2D, showAllHandles: Bool) {
            let lastIndex = path.anchors.count - 1
            for (i, a) in path.anchors.enumerated() {
                let p = transform.apply(a.position)
                let handlesVisible = showAllHandles || i >= lastIndex - 1
                if handlesVisible {
                    for h in [a.handleIn, a.handleOut].compactMap({ $0 }) {
                        let hp = transform.apply(h)
                        items.append(.polyline([p, hp], closed: false, color: accent, width: 1, dashed: false))
                        items.append(.marker(hp, shape: .circle, size: 6, fill: OverlayColors.handleFill, stroke: accent))
                    }
                }
                let isStart = i == 0 && !path.isClosed && showAllHandles == false
                items.append(.marker(p, shape: .square, size: isStart ? 9 : 7, fill: i == lastIndex && !showAllHandles ? accent : OverlayColors.handleFill, stroke: accent))
            }
        }

        if let p = pen {
            let flat = p.toPathData().flattened(curveSteps: 24)
            for sub in flat { items.append(.polyline(sub.points, closed: sub.closed, color: ink, width: 1.5, dashed: false)) }
            if let last = p.anchors.last, let hover = penHover, !p.isClosed {
                let ghost: [Point]
                if let out = last.handleOut {
                    ghost = CubicBezier(last.position, out, hover, hover).sampled(24)
                } else {
                    ghost = [last.position, hover]
                }
                items.append(.polyline(ghost, closed: false, color: OverlayColors.pen.withAlpha(0.45), width: 1, dashed: true))
            }
            drawAnchors(p, transform: .identity, showAllHandles: false)
        } else if let edit = penEdit ?? editableShape?.path, let id = penEditLayer ?? editableShape?.id,
                  let world = document.worldTransform(of: id) {
            let path = penEdit ?? edit
            drawAnchors(path, transform: world, showAllHandles: true)
        }
        return items
    }
}

extension CubicBezier {
    func sampled(_ n: Int) -> [Point] { (0...n).map { point(at: Double($0) / Double(n)) } }
}

extension RGBA {
    func withAlpha(_ a: Double) -> RGBA { RGBA(r, g, b, a) }
}
