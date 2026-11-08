import CutLine
import DocumentModel
import Foundation

/// Identifies one square tile of rendered canvas. `level` sets the density: 2^level pixels per millimetre.
/// Level 0 is 1 px/mm, level 5 is 32 px/mm (about 813 DPI). Tiles are `TileGrid.tilePixels` square.
public struct TileKey: Hashable {
    public var level: Int
    public var x: Int
    public var y: Int
    public init(level: Int, x: Int, y: Int) { self.level = level; self.x = x; self.y = y }
}

public enum TileGrid {
    public static let tilePixels = 512
    public static let minLevel = -4

    public static func pixelsPerMM(level: Int) -> Double { pow(2, Double(level)) }

    /// The size of a tile on the canvas, in millimetres.
    public static func tileSize(level: Int) -> Double { Double(tilePixels) / pixelsPerMM(level: level) }

    /// The canvas rectangle a tile covers.
    public static func rect(of key: TileKey) -> Rect2 {
        let s = tileSize(level: key.level)
        return Rect2(x: Double(key.x) * s, y: Double(key.y) * s, width: s, height: s)
    }

    /// The level to draw at: the smallest one that still gives at least one tile pixel per screen pixel.
    /// `screenPixelsPerMM` is the zoom times the screen's scale factor. Capped at the document's own DPI,
    /// since there is nothing sharper to show.
    public static func level(screenPixelsPerMM: Double, documentDPI: Double) -> Int {
        let need = max(screenPixelsPerMM, 1e-6)
        let wanted = Int(ceil(log2(need) - 1e-9))
        let cap = Int(ceil(log2(max(documentDPI, 1) / 25.4) - 1e-9))
        return min(max(wanted, minLevel), max(cap, minLevel))
    }

    /// Tiles at `level` that touch both `visible` and the canvas.
    public static func visibleTiles(visible: Rect2, canvas: Rect2, level: Int) -> [TileKey] {
        let s = tileSize(level: level)
        let area = Rect2(x: max(visible.minX, canvas.minX), y: max(visible.minY, canvas.minY),
                         width: 0, height: 0)
        let x1 = min(visible.maxX, canvas.maxX), y1 = min(visible.maxY, canvas.maxY)
        guard x1 > area.x, y1 > area.y else { return [] }
        let tx0 = Int(floor(area.x / s)), ty0 = Int(floor(area.y / s))
        let tx1 = Int(ceil(x1 / s)) - 1, ty1 = Int(ceil(y1 / s)) - 1
        guard tx1 >= tx0, ty1 >= ty0 else { return [] }
        var out: [TileKey] = []
        for ty in ty0...ty1 { for tx in tx0...tx1 { out.append(TileKey(level: level, x: tx, y: ty)) } }
        return out
    }

    /// The tile one level coarser that contains `key`.
    public static func parent(of key: TileKey) -> TileKey {
        TileKey(level: key.level - 1, x: Int(floor(Double(key.x) / 2)), y: Int(floor(Double(key.y) / 2)))
    }

    /// Tiles that cover `rect` at `level`, to find those a change makes stale.
    public static func tiles(covering rect: Rect2, level: Int) -> [TileKey] {
        visibleTiles(visible: rect, canvas: Rect2(x: -1e9, y: -1e9, width: 2e9, height: 2e9), level: level)
    }
}
