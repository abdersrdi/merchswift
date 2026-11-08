import DocumentModel
import Foundation

public struct RulerTick: Equatable {
    /// Position in millimetres.
    public var position: Double
    /// The label for a major tick, in the ruler's unit.
    public var label: String?
    public var isMajor: Bool
}

public enum RulerScale {
    /// Ticks for the part of the ruler between `range.lowerBound` and `range.upperBound` (millimetres).
    /// `pixelsPerMM` is the current zoom. Steps come from 1, 2, 5 times a power of ten in the chosen unit, so
    /// labels never crowd (at least `minLabelSpacing` points apart) and minor ticks stay at least 6 points apart.
    public static func ticks(range: ClosedRange<Double>, pixelsPerMM: Double, unit: LengthUnit, dpi: Double,
                             minLabelSpacing: Double = 60) -> [RulerTick] {
        let conv = UnitConverter(dpi: dpi)
        let pointsPerUnit = pixelsPerMM * conv.millimetres(from: 1, unit: unit)
        guard pointsPerUnit > 0, range.upperBound > range.lowerBound else { return [] }

        let major = niceStep(atLeast: minLabelSpacing / pointsPerUnit)
        let subdivisions = subdivisionCount(for: major, pointsPerUnit: pointsPerUnit)
        let minor = major / Double(subdivisions)

        let lo = conv.value(fromMillimetres: range.lowerBound, unit: unit)
        let hi = conv.value(fromMillimetres: range.upperBound, unit: unit)
        var out: [RulerTick] = []
        var i = Int((lo / minor).rounded(.down))
        let last = Int((hi / minor).rounded(.up))
        while i <= last {
            let value = Double(i) * minor
            let isMajor = i % subdivisions == 0
            let label = isMajor ? format(value, step: major) : nil
            out.append(RulerTick(position: conv.millimetres(from: value, unit: unit), label: label, isMajor: isMajor))
            i += 1
        }
        return out
    }

    static func niceStep(atLeast minimum: Double) -> Double {
        guard minimum > 0 else { return 1 }
        let exponent = floor(log10(minimum))
        let base = pow(10, exponent)
        for m in [1.0, 2, 5, 10] where m * base >= minimum * (1 - 1e-12) { return m * base }
        return 10 * base
    }

    static func subdivisionCount(for major: Double, pointsPerUnit: Double) -> Int {
        let mantissa = major / pow(10, floor(log10(major)))
        let options: [Int] = abs(mantissa - 2) < 1e-9 ? [2, 1] : (abs(mantissa - 5) < 1e-9 ? [5, 1] : [10, 5, 2, 1])
        for n in options where major / Double(n) * pointsPerUnit >= 6 { return n }
        return 1
    }

    static func format(_ value: Double, step: Double) -> String {
        let decimals = max(0, Int(-floor(log10(step) + 1e-9)))
        let v = abs(value) < step * 1e-6 ? 0 : value
        return String(format: "%.\(decimals)f", v)
    }
}
