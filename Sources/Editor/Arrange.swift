import CutLine
import DocumentModel
import Foundation

public enum AlignEdge { case left, centerX, right, top, centerY, bottom }
public enum DistributeAxis { case horizontal, vertical }

/// Pure arithmetic for aligning, distributing and numeric placement. Each function returns how far every
/// item should move; the caller applies it as one undoable change.
public enum Arrange {
    /// Moves to line the items up on `edge`, relative to the group's bounds (or `reference` when given).
    public static func align(_ rects: [Rect2], edge: AlignEdge, reference: Rect2? = nil) -> [Point] {
        guard let ref = reference ?? rects.reduce(nil, { acc, r in acc.map { $0.union(r) } ?? r }) else { return [] }
        return rects.map { r in
            switch edge {
            case .left: return Point(ref.minX - r.minX, 0)
            case .centerX: return Point(ref.midX - r.midX, 0)
            case .right: return Point(ref.maxX - r.maxX, 0)
            case .top: return Point(0, ref.minY - r.minY)
            case .centerY: return Point(0, ref.midY - r.midY)
            case .bottom: return Point(0, ref.maxY - r.maxY)
            }
        }
    }

    /// Spreads items so the gaps between neighbours are equal. The two outermost items stay where they are.
    public static func distribute(_ rects: [Rect2], axis: DistributeAxis) -> [Point] {
        guard rects.count > 2 else { return rects.map { _ in Point(0, 0) } }
        let order = rects.indices.sorted {
            axis == .horizontal ? rects[$0].minX < rects[$1].minX : rects[$0].minY < rects[$1].minY
        }
        let first = rects[order.first!], last = rects[order.last!]
        let span = axis == .horizontal ? last.maxX - first.minX : last.maxY - first.minY
        let used = order.reduce(0.0) { $0 + (axis == .horizontal ? rects[$1].width : rects[$1].height) }
        let gap = (span - used) / Double(rects.count - 1)

        var moves = [Point](repeating: Point(0, 0), count: rects.count)
        var cursor = axis == .horizontal ? first.minX : first.minY
        for i in order {
            let r = rects[i]
            if axis == .horizontal { moves[i] = Point(cursor - r.minX, 0); cursor += r.width + gap }
            else { moves[i] = Point(0, cursor - r.minY); cursor += r.height + gap }
        }
        return moves
    }

    /// The transform change that makes a layer's bounds on the canvas exactly `target` (to 0.01 mm).
    /// For a rotated layer this fits its axis-aligned bounds.
    public static func transformToFit(current: Rect2, target: Rect2) -> Transform2D? {
        guard current.width > 1e-9, current.height > 1e-9, target.width > 0, target.height > 0 else { return nil }
        let t = Rect2(x: UnitConverter.snapToPrecision(target.x), y: UnitConverter.snapToPrecision(target.y),
                      width: UnitConverter.snapToPrecision(target.width), height: UnitConverter.snapToPrecision(target.height))
        let sx = t.width / current.width, sy = t.height / current.height
        return Transform2D.translation(-current.minX, -current.minY)
            .then(.scale(sx, sy))
            .then(.translation(t.minX, t.minY))
    }
}

public extension Document {
    /// Applies a canvas-space transform to a layer, after everything it already has.
    /// With W = own.then(parent), the new own transform is own.then(parent.then(D).then(parent.inverted())).
    @discardableResult
    mutating func apply(canvasTransform d: Transform2D, to id: UUID) -> Bool {
        guard let layer = layer(id: id), let world = worldTransform(of: id),
              let ownInverse = layer.transform.inverted() else { return false }
        let parent = ownInverse.then(world)
        guard let parentInverse = parent.inverted() else { return false }
        let shift = parent.then(d).then(parentInverse)
        return update(id: id) { $0.transform = $0.transform.then(shift) }
    }

    /// Sets a layer's position and size on the canvas, in millimetres, as typed in the inspector.
    @discardableResult
    mutating func setFrame(of id: UUID, to target: Rect2) -> Bool {
        guard let current = worldBounds(of: id), let fit = Arrange.transformToFit(current: current, target: target) else { return false }
        return apply(canvasTransform: fit, to: id)
    }

    /// Moves layers by canvas-space deltas, one per id.
    mutating func translate(_ ids: [UUID], by moves: [Point]) {
        for (id, m) in zip(ids, moves) where m.x != 0 || m.y != 0 {
            apply(canvasTransform: .translation(m.x, m.y), to: id)
        }
    }
}
