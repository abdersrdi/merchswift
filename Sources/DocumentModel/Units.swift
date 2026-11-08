import Foundation

public enum LengthUnit: String, Codable, CaseIterable {
    case millimetres = "mm"
    case centimetres = "cm"
    case inches = "in"
    case pixels = "px"
}

/// Converts between the document's millimetres and what the user types or reads. Pixels depend on the document DPI.
public struct UnitConverter {
    public var dpi: Double
    public init(dpi: Double) { self.dpi = dpi }

    public func millimetres(from value: Double, unit: LengthUnit) -> Double {
        switch unit {
        case .millimetres: return value
        case .centimetres: return value * 10
        case .inches: return value * 25.4
        case .pixels: return value * 25.4 / dpi
        }
    }

    public func value(fromMillimetres mm: Double, unit: LengthUnit) -> Double {
        switch unit {
        case .millimetres: return mm
        case .centimetres: return mm / 10
        case .inches: return mm / 25.4
        case .pixels: return mm * dpi / 25.4
        }
    }

    /// Rounds to the precision the editor keeps: 0.01 mm.
    public static func snapToPrecision(_ mm: Double) -> Double { (mm * 100).rounded() / 100 }
}
