import CutLine
import DocumentModel
import Foundation

public struct SnapSettings: Equatable {
    public var threshold: Double          // millimetres
    public var toGuides = true
    public var toCanvas = true
    public var toObjects = true
    public var gridSpacing: Double?       // millimetres, nil = no grid

    public init(threshold: Double = 1.0, toGuides: Bool = true, toCanvas: Bool = true,
                toObjects: Bool = true, gridSpacing: Double? = nil) {
        self.threshold = threshold; self.toGuides = toGuides; self.toCanvas = toCanvas
        self.toObjects = toObjects; self.gridSpacing = gridSpacing
    }
}

/// A line the moving object snapped to, for drawing smart guides.
public struct SnapLine: Equatable {
    public enum Kind: Equatable { case guide, canvas, object, grid }
    public var axis: Guide.Axis      // .vertical = a line at x = position
    public var position: Double
    public var kind: Kind
}

public struct SnapResult: Equatable {
    /// What to add to the proposed move so the object sits exactly on the snapped lines.
    public var delta: Point
    public var lines: [SnapLine]
}

public enum Snapper {
    /// Snaps `moving` (already at its proposed position) to guides, canvas edges and other objects.
    /// Left, centre and right edges snap in x; top, middle and bottom in y. Each axis picks the closest
    /// candidate within the threshold.
    public static func snap(moving: Rect2, others: [Rect2], document: Document, settings: SnapSettings) -> SnapResult {
        var xTargets: [(Double, SnapLine.Kind)] = []
        var yTargets: [(Double, SnapLine.Kind)] = []

        if settings.toGuides {
            for g in document.guides {
                if g.axis == .vertical { xTargets.append((g.position, .guide)) } else { yTargets.append((g.position, .guide)) }
            }
        }
        if settings.toCanvas {
            let c = document.canvas
            xTargets += [(c.minX, .canvas), (c.midX, .canvas), (c.maxX, .canvas)]
            yTargets += [(c.minY, .canvas), (c.midY, .canvas), (c.maxY, .canvas)]
        }
        if settings.toObjects {
            for o in others {
                xTargets += [(o.minX, .object), (o.midX, .object), (o.maxX, .object)]
                yTargets += [(o.minY, .object), (o.midY, .object), (o.maxY, .object)]
            }
        }

        func best(_ edges: [Double], _ targets: [(Double, SnapLine.Kind)], grid: Bool) -> (shift: Double, line: (Double, SnapLine.Kind))? {
            var found: (shift: Double, line: (Double, SnapLine.Kind))?
            for e in edges {
                for t in targets {
                    let d = t.0 - e
                    if abs(d) <= settings.threshold, found == nil || abs(d) < abs(found!.shift) - 1e-9 { found = (d, t) }
                }
                if grid, let spacing = settings.gridSpacing, spacing > 0 {
                    let nearest = (e / spacing).rounded() * spacing
                    let d = nearest - e
                    if abs(d) <= settings.threshold, found == nil || abs(d) < abs(found!.shift) - 1e-9 { found = (d, (nearest, .grid)) }
                }
            }
            return found
        }

        let bx = best([moving.minX, moving.midX, moving.maxX], xTargets, grid: true)
        let by = best([moving.minY, moving.midY, moving.maxY], yTargets, grid: true)

        var lines: [SnapLine] = []
        if let bx { lines.append(SnapLine(axis: .vertical, position: bx.line.0, kind: bx.line.1)) }
        if let by { lines.append(SnapLine(axis: .horizontal, position: by.line.0, kind: by.line.1)) }
        return SnapResult(delta: Point(bx?.shift ?? 0, by?.shift ?? 0), lines: lines)
    }
}
