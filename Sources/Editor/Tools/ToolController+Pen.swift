import CutLine
import DocumentModel
import Foundation

extension ToolController {
    // MARK: Pen tool

    func penDown(_ e: PointerEvent) {
        // Finishing an open path: a double click, as the second click lands on the point the first one made.
        if e.clickCount >= 2, let p = pen, p.anchors.count >= 2 {
            var done = p
            if let last = done.anchors.last, let prev = done.anchors.dropLast().last, (last.position - prev.position).length < mm(6) {
                done.anchors.removeLast()
            }
            pen = done
            commitPen()
            return
        }

        // Editing the selected shape's path.
        if pen == nil, beginPenEdit(e) { return }

        let p = snappedPoint(e.canvas)
        if var current = pen {
            if current.isNearStart(p, threshold: mm(9)) {
                current.close()
                pen = current
                commitPen()
                return
            }
            current.addAnchor(at: p)
            pen = current
        } else {
            var fresh = PenPath()
            fresh.addAnchor(at: p)
            pen = fresh
            penEditLayer = nil
            penEdit = nil
        }
        interaction = .penDraw
    }

    func penDragged(_ e: PointerEvent) {
        guard let interaction else { return }
        switch interaction {
        case .penDraw:
            guard var current = pen, let anchor = current.anchors.last?.position else { return }
            var p = e.canvas
            if e.modifiers.contains(.shift) { p = constrain(p, from: anchor) }
            current.dragHandle(to: p)
            pen = current
        case .penAnchor(let index, let grab):
            guard var edit = penEdit, let local = localPoint(e.canvas) else { return }
            edit.moveAnchor(index, to: local - grab)
            writePenEdit(edit)
        case .penHandle(let index, let side):
            guard var edit = penEdit, let local = localPoint(e.canvas) else { return }
            edit.moveHandle(index, side, to: local)
            writePenEdit(edit)
        default: break
        }
    }

    func penUp(_ e: PointerEvent) {
        moved = false
    }

    /// Ends an open path where it is (the Done button, or Return).
    public func finishPath() {
        if let p = pen, p.anchors.count >= 2 { commitPen() } else { pen = nil; notify() }
    }

    func commitPen() {
        guard let p = pen, p.anchors.count >= 2 else { pen = nil; return }
        var newID: UUID?
        store.perform(p.isClosed ? "Add shape" : "Add path") { doc in
            newID = doc.addShape(from: p, name: p.isClosed ? "Shape" : "Path", fill: RGBA(0.15, 0.15, 0.17))
        }
        pen = nil
        penHover = nil
        interaction = nil
        if let id = newID { selection = [id] }
    }

    func snappedPoint(_ p: Point) -> Point {
        var settings = snapSettings
        settings.threshold = mm(6)
        settings.toObjects = false
        let r = Snapper.snap(moving: Rect2(x: p.x, y: p.y, width: 0, height: 0), others: [], document: document, settings: settings)
        return Point(p.x + r.delta.x, p.y + r.delta.y)
    }

    /// Snaps the direction from `origin` to the nearest 45 degrees.
    func constrain(_ p: Point, from origin: Point) -> Point {
        let d = p - origin
        let len = d.length
        guard len > 1e-9 else { return p }
        let step = Double.pi / 4
        let a = (atan2(d.y, d.x) / step).rounded() * step
        return Point(origin.x + cos(a) * len, origin.y + sin(a) * len)
    }

    // MARK: Editing an existing path

    /// The selected layer, if it is a single shape whose path is one outline (the only kind the pen can edit).
    var editableShape: (id: UUID, path: PenPath, world: Transform2D)? {
        guard selection.count == 1, let id = selection.first, let layer = document.layer(id: id),
              case .shape(let s) = layer.content, let world = document.worldTransform(of: id) else { return nil }
        guard s.path.elements.filter({ if case .move = $0 { return true } else { return false } }).count == 1 else { return nil }
        return (id, PenPath(pathData: s.path), world)
    }

    func localPoint(_ canvas: Point) -> Point? {
        guard let id = penEditLayer, let world = document.worldTransform(of: id), let inv = world.inverted() else { return nil }
        return inv.apply(canvas)
    }

    private func beginPenEdit(_ e: PointerEvent) -> Bool {
        guard let editable = editableShape, let inv = editable.world.inverted() else { return false }
        let local = inv.apply(e.canvas)
        let scale = max(abs(editable.world.determinant).squareRoot(), 1e-9)
        guard let hit = editable.path.hitTest(local, tolerance: mm(8) / scale) else { return false }

        penEditLayer = editable.id
        var edit = editable.path
        beginInteraction()
        switch hit {
        case .anchor(let i):
            if e.clickCount >= 2 {
                edit.toggleSmooth(i)
                writePenEdit(edit)
                interaction = nil
            } else {
                penEdit = edit
                interaction = .penAnchor(index: i, grab: local - edit.anchors[i].position)
            }
        case .handleIn(let i):
            penEdit = edit
            interaction = .penHandle(index: i, side: .handleIn)
        case .handleOut(let i):
            penEdit = edit
            interaction = .penHandle(index: i, side: .handleOut)
        case .segment(let i, let t):
            if let n = edit.insertAnchor(afterSegment: i, at: t) {
                writePenEdit(edit)
                interaction = .penAnchor(index: n, grab: Point(0, 0))
            }
        }
        if penEdit == nil { penEdit = edit }
        return true
    }

    func writePenEdit(_ edit: PenPath) {
        guard let id = penEditLayer else { return }
        penEdit = edit
        let key = interactionKey
        store.perform("Edit path", coalesceKey: key, window: .infinity) { doc in
            doc.update(id: id) { layer in
                if case .shape(var s) = layer.content { s.path = edit.toPathData(); layer.content = .shape(s) }
            }
        }
    }

    /// Deletes the anchor under the pointer's last edit, or the last point being drawn.
    func penDeleteKey() -> Bool {
        if var p = pen, !p.anchors.isEmpty {
            p.anchors.removeLast()
            pen = p.anchors.isEmpty ? nil : p
            return true
        }
        return false
    }
}
