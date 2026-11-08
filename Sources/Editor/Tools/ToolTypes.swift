import CutLine
import DocumentModel
import Foundation

public struct Modifiers: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1)
    public static let option = Modifiers(rawValue: 2)
    public static let command = Modifiers(rawValue: 4)
    public static let control = Modifiers(rawValue: 8)
}

public enum Tool: String, CaseIterable {
    case select, pen
}

public enum PointerKind { case mouse, touch, pencil }

/// One pointer event. `canvas` is in millimetres, `screen` in view points.
public struct PointerEvent {
    public var canvas: Point
    public var screen: Point
    public var modifiers: Modifiers
    public var kind: PointerKind
    public var clickCount: Int

    public init(canvas: Point, screen: Point = Point(0, 0), modifiers: Modifiers = [], kind: PointerKind = .mouse, clickCount: Int = 1) {
        self.canvas = canvas; self.screen = screen; self.modifiers = modifiers; self.kind = kind; self.clickCount = clickCount
    }
}

public enum ToolKey: Equatable {
    case delete, escape, enter
    case arrow(dx: Int, dy: Int)
    case character(Character)
}

public enum SelectionHandle: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, rotate
}

public enum MarkerShape { case square, circle, diamond }

/// A drawing instruction for the tool overlay. Positions are canvas millimetres; sizes and widths are screen points,
/// so handles keep their size at every zoom.
public enum OverlayItem: Equatable {
    case polyline([Point], closed: Bool, color: RGBA, width: Double, dashed: Bool)
    case marker(Point, shape: MarkerShape, size: Double, fill: RGBA, stroke: RGBA)
    case rectFill(Rect2, color: RGBA)
}

public enum OverlayColors {
    public static let accent = RGBA(0.16, 0.52, 1.0)
    public static let accentSoft = RGBA(0.16, 0.52, 1.0, 0.14)
    public static let guide = RGBA(1.0, 0.2, 0.7)
    public static let handleFill = RGBA(1, 1, 1)
    public static let pen = RGBA(0.1, 0.1, 0.12)
}
