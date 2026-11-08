import CutLine
import DocumentModel
import Foundation

public extension Document {
    /// A shape layer's outline in canvas coordinates.
    func worldPath(of id: UUID) -> PathData? {
        guard let l = layer(id: id), case .shape(let s) = l.content, let t = worldTransform(of: id) else { return nil }
        return s.path.transformed(by: t)
    }

    /// Combines shape layers into one new shape. The first layer (lowest in the stack) is the subject, and its fill and
    /// stroke carry over. For `.subtract`, every other layer is cut out of it. Returns the new layer's ID, or nil when
    /// fewer than two shape layers were given or the result is empty. The sources are removed.
    @discardableResult
    mutating func combine(_ ids: [UUID], _ op: BooleanOperation, name: String? = nil) -> UUID? {
        // Stack order, bottom first, so "the first" does not depend on selection order.
        func order(_ list: [Layer], _ out: inout [UUID]) {
            for l in list { if ids.contains(l.id) { out.append(l.id) }; order(l.children, &out) }
        }
        var ordered: [UUID] = []
        order(layers, &ordered)
        guard ordered.count >= 2 else { return nil }

        var shapes: [(UUID, ShapeContent, PathData)] = []
        for id in ordered {
            guard let l = layer(id: id), case .shape(let s) = l.content, let path = worldPath(of: id) else { return nil }
            shapes.append((id, s, path))
        }

        var result = shapes[0].2
        for next in shapes.dropFirst() { result = PathBoolean.perform(op, subject: result, clip: next.2) }
        guard !result.elements.isEmpty else { return nil }

        let style = shapes[0].1
        let top = shapes.last!.0

        func place(of id: UUID, in list: [Layer], parent: UUID?) -> (UUID?, Int)? {
            if let i = list.firstIndex(where: { $0.id == id }) { return (parent, i) }
            for l in list { if let r = place(of: id, in: l.children, parent: l.id) { return r } }
            return nil
        }
        guard let topPlace = place(of: top, in: layers, parent: nil) else { return nil }
        // Sources below the top one in the same list disappear, which moves the top one's slot down.
        let shift = shapes.dropLast().filter { shape in
            guard let p = place(of: shape.0, in: layers, parent: nil) else { return false }
            return p.0 == topPlace.0 && p.1 < topPlace.1
        }.count

        for shape in shapes { remove(id: shape.0) }
        var layer = Layer(name: name ?? "Combined shape",
                          content: .shape(ShapeContent(path: result, fill: style.fill, stroke: style.stroke)))
        let index = topPlace.1 - shift
        if let parent = topPlace.0 {
            // Inside a group the result is expressed in the group's own coordinates.
            if let world = worldTransform(of: parent), let inv = world.inverted(), case .shape(var s) = layer.content {
                s.path = s.path.transformed(by: inv)
                layer.content = .shape(s)
            }
            insert(layer, in: parent, at: index)
        } else {
            insert(layer, at: index)
        }
        return layer.id
    }

    /// Adds a new shape layer from a pen path (in canvas millimetres) on top of the stack.
    @discardableResult
    mutating func addShape(from pen: PenPath, name: String = "Path", fill: RGBA? = RGBA.black, stroke: Stroke? = nil) -> UUID {
        let layer = Layer(name: name, content: .shape(ShapeContent(path: pen.toPathData(), fill: pen.isClosed ? fill : nil,
                                                                  stroke: pen.isClosed ? stroke : (stroke ?? Stroke(color: .black, width: 0.5)))))
        insert(layer)
        return layer.id
    }
}
