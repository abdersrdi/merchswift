import Foundation

/// Traces the 0.5 iso-line of a float field into closed polylines, with linear interpolation,
/// so the outline is sub-pixel accurate. The field must be below 0.5 along its whole border.
enum MarchingSquares {
    private enum Edge { case top, right, bottom, left }

    static func contours(field: [Float], width: Int, height: Int, level: Float = 0.5) -> [[Point]] {
        // Edge ids: horizontal edge between (x,y)-(x+1,y) is (y*width+x)*2, vertical between (x,y)-(x,y+1) is +1.
        func hid(_ x: Int, _ y: Int) -> Int { (y * width + x) * 2 }
        func vid(_ x: Int, _ y: Int) -> Int { (y * width + x) * 2 + 1 }
        func edgeId(_ e: Edge, _ x: Int, _ y: Int) -> Int {
            switch e {
            case .top: return hid(x, y)
            case .bottom: return hid(x, y + 1)
            case .left: return vid(x, y)
            case .right: return vid(x + 1, y)
            }
        }

        var segments: [(Int, Int)] = []
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let tl = field[y * width + x], tr = field[y * width + x + 1]
                let bl = field[(y + 1) * width + x], br = field[(y + 1) * width + x + 1]
                var idx = 0
                if tl > level { idx |= 1 }
                if tr > level { idx |= 2 }
                if br > level { idx |= 4 }
                if bl > level { idx |= 8 }
                if idx == 0 || idx == 15 { continue }
                var pairs: [(Edge, Edge)]
                switch idx {
                case 1, 14: pairs = [(.left, .top)]
                case 2, 13: pairs = [(.top, .right)]
                case 3, 12: pairs = [(.left, .right)]
                case 4, 11: pairs = [(.right, .bottom)]
                case 6, 9: pairs = [(.top, .bottom)]
                case 7, 8: pairs = [(.left, .bottom)]
                case 5:
                    let centre = (tl + tr + bl + br) / 4
                    pairs = centre > level ? [(.top, .right), (.left, .bottom)] : [(.left, .top), (.right, .bottom)]
                default: // 10
                    let centre = (tl + tr + bl + br) / 4
                    pairs = centre > level ? [(.left, .top), (.right, .bottom)] : [(.top, .right), (.left, .bottom)]
                }
                for p in pairs { segments.append((edgeId(p.0, x, y), edgeId(p.1, x, y))) }
            }
        }

        // Each edge id is shared by exactly two segments, so loops can be walked by id.
        var byEdge: [Int: [Int]] = [:]
        for (i, s) in segments.enumerated() {
            byEdge[s.0, default: []].append(i)
            byEdge[s.1, default: []].append(i)
        }

        func position(_ id: Int) -> Point {
            let horizontal = id % 2 == 0
            let cell = id / 2
            let x = cell % width, y = cell / width
            if horizontal {
                let a = field[y * width + x], b = field[y * width + x + 1]
                let t = Double((level - a) / (b - a))
                return Point(Double(x) + t, Double(y))
            } else {
                let a = field[y * width + x], b = field[(y + 1) * width + x]
                let t = Double((level - a) / (b - a))
                return Point(Double(x), Double(y) + t)
            }
        }

        var used = [Bool](repeating: false, count: segments.count)
        var loops: [[Point]] = []
        for start in 0..<segments.count where !used[start] {
            var loop: [Point] = []
            var current = start
            var entry = segments[start].0
            var guardCount = 0
            while !used[current] {
                used[current] = true
                let s = segments[current]
                let exit = (s.0 == entry) ? s.1 : s.0
                loop.append(position(entry))
                let candidates = byEdge[exit] ?? []
                guard let next = candidates.first(where: { $0 != current && !used[$0] }) else { break }
                current = next
                entry = exit
                guardCount += 1
                if guardCount > segments.count { break }
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    static func signedArea(_ pts: [Point]) -> Double {
        var a = 0.0
        for i in 0..<pts.count {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }
}
