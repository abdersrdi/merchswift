import CutLine
import Foundation

/// Width and height in millimetres.
public struct Size2: Codable, Equatable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
}

/// An axis-aligned rectangle in millimetres.
public struct Rect2: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: Point { Point(midX, midY) }

    public func contains(_ p: Point) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    public func intersects(_ o: Rect2) -> Bool { minX <= o.maxX && maxX >= o.minX && minY <= o.maxY && maxY >= o.minY }

    public func union(_ o: Rect2) -> Rect2 {
        let x0 = min(minX, o.minX), y0 = min(minY, o.minY)
        return Rect2(x: x0, y: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
    }

    public func offsetBy(dx: Double, dy: Double) -> Rect2 { Rect2(x: x + dx, y: y + dy, width: width, height: height) }

    public static func bounding(_ points: [Point]) -> Rect2? {
        guard var lo = points.first else { return nil }
        var hi = lo
        for p in points { lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y) }
        return Rect2(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }
}

/// A 2D affine transform: x' = a x + c y + tx, y' = b x + d y + ty.
public struct Transform2D: Codable, Equatable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Transform2D()

    public static func translation(_ dx: Double, _ dy: Double) -> Transform2D { Transform2D(tx: dx, ty: dy) }
    public static func scale(_ sx: Double, _ sy: Double) -> Transform2D { Transform2D(a: sx, d: sy) }
    public static func rotation(_ radians: Double) -> Transform2D {
        Transform2D(a: cos(radians), b: sin(radians), c: -sin(radians), d: cos(radians))
    }

    public func apply(_ p: Point) -> Point { Point(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }

    /// The transform that applies `self` first and then `other`.
    public func then(_ other: Transform2D) -> Transform2D {
        Transform2D(a: other.a * a + other.c * b, b: other.b * a + other.d * b,
                    c: other.a * c + other.c * d, d: other.b * c + other.d * d,
                    tx: other.a * tx + other.c * ty + other.tx, ty: other.b * tx + other.d * ty + other.ty)
    }

    public var determinant: Double { a * d - b * c }

    public func inverted() -> Transform2D? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return Transform2D(a: ia, b: ib, c: ic, d: id, tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }

    /// Bounding box of `rect` after the transform.
    public func apply(_ rect: Rect2) -> Rect2 {
        let pts = [Point(rect.minX, rect.minY), Point(rect.maxX, rect.minY), Point(rect.maxX, rect.maxY), Point(rect.minX, rect.maxY)]
        return Rect2.bounding(pts.map(apply))!
    }
}

public struct RGBA: Codable, Equatable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
}
