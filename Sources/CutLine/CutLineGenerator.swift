import Foundation

public struct CutLineOptions {
    /// Distance from the artwork edge to the cut line, in pixels of the input image.
    public var offset: Double
    /// Radius of the rounding applied to concave notches, in pixels. 0 keeps every notch.
    public var smoothing: Double
    /// Pixels at or above this alpha count as artwork (0...255).
    public var alphaThreshold: UInt8
    /// Largest allowed distance between the fitted curve and the traced outline, in pixels.
    public var tolerance: Double
    /// Separate pieces smaller than this fraction of the largest piece are treated as dust and ignored.
    public var minPieceFraction: Double

    public init(offset: Double, smoothing: Double = 0, alphaThreshold: UInt8 = 128,
                tolerance: Double = 0.35, minPieceFraction: Double = 0.002) {
        self.offset = offset
        self.smoothing = smoothing
        self.alphaThreshold = alphaThreshold
        self.tolerance = tolerance
        self.minPieceFraction = minPieceFraction
    }
}

public enum CutLineError: Error, Equatable {
    case emptyArtwork
    case traceFailed
}

public enum CutLineGenerator {
    /// Builds the cut line around the artwork in `image`.
    ///
    /// The artwork is grown by the offset with an exact Euclidean distance transform, interior holes are
    /// filled, and the result is traced and fitted with cubic Beziers. Because the outline is traced from a
    /// mask, each shape gets exactly one closed path and the path cannot cross itself.
    /// Coordinates in the result are image pixels (y down, origin top left).
    public static func generate(from image: AlphaImage, options: CutLineOptions) throws -> CutPath {
        let reach = options.offset + options.smoothing
        let pad = Int(reach.rounded(.up)) + 6
        let w = image.width + pad * 2
        let h = image.height + pad * 2

        var mask = [Bool](repeating: false, count: w * h)
        var any = false
        for y in 0..<image.height {
            for x in 0..<image.width where image.alpha[y * image.width + x] >= options.alphaThreshold {
                mask[(y + pad) * w + x + pad] = true
                any = true
            }
        }
        guard any else { throw CutLineError.emptyArtwork }

        mask = RasterOps.dropSmallComponents(mask, width: w, height: h, fraction: options.minPieceFraction)
        mask = RasterOps.dilate(mask, width: w, height: h, radius: reach)
        if options.smoothing > 0 {
            mask = RasterOps.erode(mask, width: w, height: h, radius: options.smoothing)
        }
        mask = RasterOps.fillHoles(mask, width: w, height: h)

        let field = RasterOps.blur(mask, width: w, height: h, sigma: 1.1)
        let loops = MarchingSquares.contours(field: field, width: w, height: h)
        guard !loops.isEmpty else { throw CutLineError.traceFailed }

        var contours: [Contour] = []
        for loop in loops {
            // Grid to image space: pixel centre (x, y) sits at (x + 0.5, y + 0.5).
            var pts = loop.map { Point($0.x - Double(pad) + 0.5, $0.y - Double(pad) + 0.5) }
            if MarchingSquares.signedArea(pts) < 0 { pts.reverse() }
            if abs(MarchingSquares.signedArea(pts)) < 4 { continue }
            if let c = BezierFit.fitClosed(pts, tolerance: options.tolerance) { contours.append(c) }
        }
        guard !contours.isEmpty else { throw CutLineError.traceFailed }
        return CutPath(contours: contours)
    }
}


public enum PolygonFit {
    /// Turns a closed polygon into cubic Beziers, keeping real corners sharp and re-smoothing runs that came from a curve.
    public static func fitClosed(_ polygon: [Point], tolerance: Double = 0.01, cornerAngleDegrees: Double = 25) -> Contour? {
        BezierFit.fitClosedPolygon(polygon, tolerance: tolerance, cornerAngleDegrees: cornerAngleDegrees)
    }
}
