import Foundation

/// Just the alpha channel of an image, 8 bits per pixel, row 0 at the top.
public struct AlphaImage {
    public let width: Int
    public let height: Int
    public var alpha: [UInt8]

    public init(width: Int, height: Int, alpha: [UInt8]) {
        precondition(alpha.count == width * height, "alpha size does not match the dimensions")
        self.width = width
        self.height = height
        self.alpha = alpha
    }

    /// Takes the alpha out of interleaved 8-bit RGBA pixels.
    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "RGBA size does not match the dimensions")
        var a = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) { a[i] = rgba[i * 4 + 3] }
        self.init(width: width, height: height, alpha: a)
    }
}
