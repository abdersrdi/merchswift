import CutLine
import DocumentModel
import Foundation

/// Where a case's camera sits on the back, seen from behind with the phone upright (top left corner).
public enum CameraGuide: Equatable {
    case none
    case square(Double)
    case pill(width: Double, height: Double)
    /// A full-width raised band across the top.
    case plateau(height: Double)
    case singleLens(Double)

    var label: String {
        switch self {
        case .none: return "no camera"
        case .square: return "square camera"
        case .pill: return "vertical pill camera"
        case .plateau: return "full-width camera plateau"
        case .singleLens: return "single camera"
        }
    }

    var code: String {
        switch self {
        case .none: return "none"
        case .square(let s): return "sq\(Int(s.rounded()))"
        case .pill(let w, let h): return "pill\(Int(w.rounded()))x\(Int(h.rounded()))"
        case .plateau(let h): return "plateau\(Int(h.rounded()))"
        case .singleLens(let s): return "one\(Int(s.rounded()))"
        }
    }
}

/// One device's size, from the maker's published dimensions, and its camera guide. Rows carry no brand or model names:
/// the app labels cases by what a person can check on their own device (its size and camera layout).
public struct DeviceCaseSpec: Equatable {
    public enum Kind: Equatable { case phone, tablet }
    public var kind: Kind
    /// Millimetres.
    public var height: Double
    public var width: Double
    public var depth: Double
    public var camera: CameraGuide

    public init(_ kind: Kind, height: Double, width: Double, depth: Double, camera: CameraGuide) {
        self.kind = kind; self.height = height; self.width = width; self.depth = depth; self.camera = camera
    }
}

/// Print files for the backs of phone and tablet cases. The canvas is the device's own size plus 3 mm of bleed on every
/// side, at 300 DPI, which is what most print suppliers ask for. These are generic templates made from public device
/// sizes, not a supplier's own template, and the camera guide is approximate, so the note says to confirm with the
/// print supplier before a production run.
public enum DeviceCaseCatalog {
    static let bleed = 3.0
    static let safeInset = 5.0
    /// Distance of the camera guide from the side and top edge of the device.
    static let cameraInset = 5.0

    /// The devices in the catalogue. Devices with the same size and camera layout share one row.
    /// Adding a new device is adding one row here.
    public static let specs: [DeviceCaseSpec] = [
        // Phones
        DeviceCaseSpec(.phone, height: 147.6, width: 71.6, depth: 7.8, camera: .square(32)),
        DeviceCaseSpec(.phone, height: 160.9, width: 77.8, depth: 7.8, camera: .square(32)),
        DeviceCaseSpec(.phone, height: 146.6, width: 70.6, depth: 8.25, camera: .square(36)),
        DeviceCaseSpec(.phone, height: 159.9, width: 76.7, depth: 8.25, camera: .square(37)),
        DeviceCaseSpec(.phone, height: 147.6, width: 71.6, depth: 7.8, camera: .pill(width: 20, height: 38)),
        DeviceCaseSpec(.phone, height: 160.9, width: 77.8, depth: 7.8, camera: .pill(width: 21, height: 39)),
        DeviceCaseSpec(.phone, height: 149.6, width: 71.5, depth: 8.25, camera: .square(36)),
        DeviceCaseSpec(.phone, height: 163.0, width: 77.6, depth: 8.25, camera: .square(38)),
        DeviceCaseSpec(.phone, height: 146.7, width: 71.5, depth: 7.8, camera: .singleLens(15)),
        DeviceCaseSpec(.phone, height: 149.6, width: 71.5, depth: 7.95, camera: .pill(width: 21, height: 39)),
        DeviceCaseSpec(.phone, height: 156.2, width: 74.7, depth: 5.64, camera: .plateau(height: 22)),
        DeviceCaseSpec(.phone, height: 150.0, width: 71.9, depth: 8.75, camera: .plateau(height: 40)),
        DeviceCaseSpec(.phone, height: 163.4, width: 78.0, depth: 8.75, camera: .plateau(height: 42)),
        // Tablets
        DeviceCaseSpec(.tablet, height: 281.6, width: 215.5, depth: 5.1, camera: .square(30)),
        DeviceCaseSpec(.tablet, height: 249.7, width: 177.5, depth: 5.3, camera: .square(30)),
        DeviceCaseSpec(.tablet, height: 247.6, width: 178.5, depth: 6.1, camera: .square(30)),
    ]

    public static let all: [ProductPreset] = specs.map(preset(for:))

    public static func preset(id: String) -> ProductPreset? { all.first { $0.id == id } }

    public static func preset(for spec: DeviceCaseSpec) -> ProductPreset {
        let trim = Size2(spec.width, spec.height)
        let zone = cameraZone(spec.camera, trim: trim)
        let isPhone = spec.kind == .phone
        let inches = String(format: "%.1f × %.1f in", spec.height / 25.4, spec.width / 25.4)
        let name = (isPhone ? "Phone case" : "Tablet case") + " · \(inches) · \(spec.camera.label)"
        let id = "case-\(isPhone ? "p" : "t")-\(Int((spec.height * 10).rounded()))x\(Int((spec.width * 10).rounded()))-\(spec.camera.code)"
        return ProductPreset(
            id: id, name: name, kind: .deviceCase, trim: trim, bleed: bleed, safeInset: safeInset, dpi: 300,
            requiresFullBleed: true, restrictedZones: zone.map { [$0] } ?? [], exports: [.png, .pdfX4],
            note: "A generic back template: the device's own size plus \(Int(bleed)) mm of bleed on every side, at 300 DPI. It is not a "
                + "print supplier's template, and the camera guide is approximate. Confirm the size and the camera position with your "
                + "supplier before a production run.",
            restrictedZoneName: "camera",
            restrictedZoneAdvice: "The camera sits here and hides or cuts into the print. Keep faces, text and logos out of this area; the background can run behind it.")
    }

    /// The camera area in canvas coordinates (the trim starts at the bleed).
    static func cameraZone(_ camera: CameraGuide, trim: Size2) -> Rect2? {
        let x = bleed + cameraInset, y = bleed + cameraInset
        switch camera {
        case .none: return nil
        case .square(let s), .singleLens(let s): return Rect2(x: x, y: y, width: s, height: s)
        case .pill(let w, let h): return Rect2(x: x, y: y, width: w, height: h)
        case .plateau(let h): return Rect2(x: bleed, y: bleed, width: trim.width, height: h)
        }
    }

    /// The print file's size in pixels at the preset's resolution.
    public static func pixelSize(of preset: ProductPreset) -> (width: Int, height: Int) {
        (Int((preset.canvas.width * preset.dpi / 25.4).rounded()), Int((preset.canvas.height * preset.dpi / 25.4).rounded()))
    }
}
