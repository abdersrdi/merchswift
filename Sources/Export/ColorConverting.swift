import Foundation
import DocumentModel

/// Turns screen colours into CMYK ink amounts through an ICC profile. The app's implementation uses ColorSync;
/// tests use a plain formula.
public protocol ColorConverting {
    /// Amounts of cyan, magenta, yellow and black, each from 0 to 1.
    func cmyk(from color: RGBA) -> (c: Double, m: Double, y: Double, k: Double)
    /// Converts straight-alpha RGBA pixels to interleaved cyan, magenta, yellow, black and alpha: five bytes a pixel.
    func cmykPixels(_ image: RGBAImage) -> [UInt8]
    /// The ICC profile bytes embedded as the output intent.
    var profile: Data { get }
    /// What the output intent calls the printing condition.
    var conditionName: String { get }
}

/// How a PDF is coloured.
public enum PDFColorMode {
    case rgb
    case cmyk(ColorConverting)
}
