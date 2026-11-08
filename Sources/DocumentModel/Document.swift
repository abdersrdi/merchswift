import CutLine
import Foundation

public struct Guide: Codable, Equatable, Identifiable {
    public enum Axis: String, Codable { case horizontal, vertical }
    public var id: UUID
    public var axis: Axis
    /// Position in millimetres: y for a horizontal guide, x for a vertical one.
    public var position: Double
    public init(id: UUID = UUID(), axis: Axis, position: Double) { self.id = id; self.axis = axis; self.position = position }
}

/// A design: a canvas of a fixed size in millimetres and a stack of layers, bottom first.
public struct Document: Codable, Equatable {
    public var formatVersion = 1
    public var title: String
    public var size: Size2
    public var dpi: Double
    public var presetID: String?
    public var layers: [Layer]
    public var guides: [Guide]

    public init(title: String = "Untitled", size: Size2, dpi: Double = 300, presetID: String? = nil,
                layers: [Layer] = [], guides: [Guide] = []) {
        self.title = title; self.size = size; self.dpi = dpi; self.presetID = presetID
        self.layers = layers; self.guides = guides
    }

    public var canvas: Rect2 { Rect2(x: 0, y: 0, width: size.width, height: size.height) }
    public var units: UnitConverter { UnitConverter(dpi: dpi) }

    // MARK: Finding

    public func layer(id: UUID) -> Layer? {
        func search(_ list: [Layer]) -> Layer? {
            for l in list {
                if l.id == id { return l }
                if let f = search(l.children) { return f }
            }
            return nil
        }
        return search(layers)
    }

    /// Transform from the layer's own coordinates to the canvas.
    public func worldTransform(of id: UUID) -> Transform2D? {
        func search(_ list: [Layer], _ parent: Transform2D) -> Transform2D? {
            for l in list {
                let t = l.transform.then(parent)
                if l.id == id { return t }
                if let f = search(l.children, t) { return f }
            }
            return nil
        }
        return search(layers, .identity)
    }

    /// Bounds on the canvas.
    public func worldBounds(of id: UUID) -> Rect2? {
        guard let l = layer(id: id), let t = worldTransform(of: id), let b = l.localBounds else { return nil }
        return t.apply(b)
    }

    // MARK: Editing

    @discardableResult
    public mutating func update(id: UUID, _ change: (inout Layer) -> Void) -> Bool {
        func apply(_ list: inout [Layer]) -> Bool {
            for i in list.indices {
                if list[i].id == id { change(&list[i]); return true }
                if case .group(var kids) = list[i].content {
                    if apply(&kids) { list[i].content = .group(kids); return true }
                }
            }
            return false
        }
        return apply(&layers)
    }

    @discardableResult
    public mutating func remove(id: UUID) -> Layer? {
        func take(_ list: inout [Layer]) -> Layer? {
            if let i = list.firstIndex(where: { $0.id == id }) { return list.remove(at: i) }
            for i in list.indices {
                if case .group(var kids) = list[i].content, let found = take(&kids) {
                    list[i].content = .group(kids)
                    return found
                }
            }
            return nil
        }
        return take(&layers)
    }

    /// Inserts into the root (`parent == nil`) or into a group. `index` is clamped; the top of the stack is the end.
    @discardableResult
    public mutating func insert(_ layer: Layer, in parent: UUID? = nil, at index: Int? = nil) -> Bool {
        guard let parent else {
            layers.insert(layer, at: min(max(index ?? layers.count, 0), layers.count))
            return true
        }
        return update(id: parent) { p in
            guard case .group(var kids) = p.content else { return }
            kids.insert(layer, at: min(max(index ?? kids.count, 0), kids.count))
            p.content = .group(kids)
        } && (self.layer(id: layer.id) != nil)
    }

    /// Moves a layer to another place in the stack without changing where it appears on the canvas.
    @discardableResult
    public mutating func move(id: UUID, toParent parent: UUID?, at index: Int? = nil) -> Bool {
        guard let before = worldTransform(of: id), let layer = self.layer(id: id) else { return false }
        if let parent {
            // A layer cannot move into itself or one of its own children.
            if parent == id || layer.children.contains(where: { containsLayer($0, id: parent) }) { return false }
            guard case .group? = self.layer(id: parent)?.content else { return false }
        }
        guard var moved = remove(id: id) else { return false }
        let parentWorld = parent.flatMap { worldTransform(of: $0) } ?? .identity
        if let inv = parentWorld.inverted() { moved.transform = before.then(inv) }
        return insert(moved, in: parent, at: index)
    }

    private func containsLayer(_ l: Layer, id: UUID) -> Bool {
        l.id == id || l.children.contains { containsLayer($0, id: id) }
    }

    /// Wraps the given top-level-or-nested layers (that share one parent) in a new group, at the top-most one's place.
    @discardableResult
    public mutating func group(ids: [UUID], name: String = "Group") -> UUID? {
        guard !ids.isEmpty else { return nil }
        func parentAndIndex(_ id: UUID, in list: [Layer], parent: UUID?) -> (UUID?, Int)? {
            if let i = list.firstIndex(where: { $0.id == id }) { return (parent, i) }
            for l in list {
                if let r = parentAndIndex(id, in: l.children, parent: l.id) { return r }
            }
            return nil
        }
        let places = ids.compactMap { parentAndIndex($0, in: layers, parent: nil) }
        guard places.count == ids.count, Set(places.map { $0.0 }).count == 1, Set(ids).count == ids.count else { return nil }
        let parent = places[0].0
        let top = places.map { $0.1 }.max()!
        var members: [(Int, Layer)] = []
        for (id, place) in zip(ids, places) {
            guard let l = layer(id: id) else { return nil }
            members.append((place.1, l))
        }
        members.sort { $0.0 < $1.0 }
        for id in ids { remove(id: id) }
        let g = Layer(name: name, content: .group(members.map { $0.1 }))
        insert(g, in: parent, at: top - (members.count - 1))
        return g.id
    }

    /// Replaces a group by its children, keeping them where they appear on the canvas.
    @discardableResult
    public mutating func ungroup(id: UUID) -> Bool {
        guard let g = layer(id: id), case .group(let kids) = g.content else { return false }
        func locate(_ list: [Layer], parent: UUID?) -> (UUID?, Int)? {
            if let i = list.firstIndex(where: { $0.id == id }) { return (parent, i) }
            for l in list { if let r = locate(l.children, parent: l.id) { return r } }
            return nil
        }
        guard let (parent, index) = locate(layers, parent: nil) else { return false }
        remove(id: id)
        for (offset, var k) in kids.enumerated() {
            k.transform = k.transform.then(g.transform)
            insert(k, in: parent, at: index + offset)
        }
        return true
    }

    // MARK: Hit testing

    /// The top-most visible layer under `point` (canvas coordinates). Locked layers are skipped unless asked for.
    public func hitTest(_ point: Point, includeLocked: Bool = false, tolerance: Double = 0) -> UUID? {
        func test(_ list: [Layer], _ parent: Transform2D) -> UUID? {
            for l in list.reversed() where l.isVisible {
                let t = l.transform.then(parent)
                if case .group(let kids) = l.content {
                    if let hit = test(kids, t) { return hit }
                    continue
                }
                if l.isLocked && !includeLocked { continue }
                guard let inv = t.inverted() else { continue }
                let local = inv.apply(point)
                let scale = max(abs(t.determinant).squareRoot(), 1e-9)
                if hits(l, local, tolerance: tolerance / scale) { return l.id }
            }
            return nil
        }
        return test(layers, .identity)
    }

    private func hits(_ l: Layer, _ p: Point, tolerance: Double) -> Bool {
        switch l.content {
        case .image(let i):
            return Rect2(x: -tolerance, y: -tolerance, width: i.size.width + 2 * tolerance, height: i.size.height + 2 * tolerance).contains(p)
        case .shape(let s):
            let polys = s.path.flattened()
            if s.fill != nil {
                var inside = false
                for poly in polys where poly.closed && Self.pointInPolygonNonZero(p, poly.points) { inside = true }
                if inside { return true }
            }
            let half = (s.stroke?.width ?? 0) / 2 + tolerance
            if s.stroke != nil || tolerance > 0 {
                for poly in polys {
                    let pts = poly.points
                    guard pts.count > 1 else { continue }
                    let count = poly.closed ? pts.count : pts.count - 1
                    for i in 0..<count where Self.distance(from: p, toSegment: pts[i], pts[(i + 1) % pts.count]) <= half { return true }
                }
            }
            return false
        case .group:
            return false
        }
    }

    static func pointInPolygonNonZero(_ p: Point, _ poly: [Point]) -> Bool {
        var winding = 0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if a.y <= p.y {
                if b.y > p.y && isLeft(a, b, p) > 0 { winding += 1 }
            } else if b.y <= p.y && isLeft(a, b, p) < 0 {
                winding -= 1
            }
        }
        return winding != 0
    }

    private static func isLeft(_ a: Point, _ b: Point, _ p: Point) -> Double { (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) }

    static func distance(from p: Point, toSegment a: Point, _ b: Point) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        if len2 < 1e-18 { return (p - a).length }
        let t = max(0, min(1, (p - a).dot(ab) / len2))
        return (p - (a + ab * t)).length
    }
}
