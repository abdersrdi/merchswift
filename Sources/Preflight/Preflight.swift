import CutLine
import DocumentModel
import Foundation
import Products

public enum PreflightCheck: String, CaseIterable {
    case resolution, safeArea, bleed, thinLine, smallText, semiTransparency, gamut, fonts, cutLine, mugHandle
}

public enum Severity: Int, Comparable {
    case error = 0, warning = 1, info = 2
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

public enum ColorTarget: Equatable { case fill, stroke }

/// A change that fixes an issue in one step.
public enum PreflightFix: Equatable {
    /// Needs the on-device upscaler (milestone 5); until then applying it does nothing.
    case upscaleImage(layer: UUID, targetDPI: Double)
    case move(layer: UUID, dx: Double, dy: Double)
    case extendToBleed(layer: UUID)
    case thickenStroke(layer: UUID, to: Double)
    case enlargeText(layer: UUID, size: Double)
    case removeTransparency(layer: UUID)
    case replaceColor(layer: UUID, target: ColorTarget, with: RGBA)
    case setCutOffset(Double)
    case simplifyCutLine
}

public struct PreflightIssue: Identifiable, Equatable {
    public var id: String
    public var check: PreflightCheck
    public var severity: Severity
    public var layerID: UUID?
    /// One line naming the problem.
    public var title: String
    /// What it means in plain language.
    public var detail: String
    public var fix: PreflightFix?
    public var fixTitle: String?
}

/// Tells whether an RGB colour can be printed in CMYK and what the nearest printable colour is.
public protocol GamutChecking {
    func isInGamut(_ color: RGBA) -> Bool
    func nearestInGamut(_ color: RGBA) -> RGBA
}

public struct PreflightReport: Equatable {
    public var issues: [PreflightIssue]
    public var errors: Int { issues.filter { $0.severity == .error }.count }
    public var warnings: Int { issues.filter { $0.severity == .warning }.count }
    public var isClean: Bool { issues.isEmpty }
    /// Errors block export; warnings only inform.
    public var canExport: Bool { errors == 0 }
}

/// The print checks, run before every export and on demand. Each explains the problem plainly and, where it can,
/// carries the fix.
public enum Preflight {
    static let minLineMM = 0.25
    static let minTextPoints = 6.0
    static let pointsPerMM = 72.0 / 25.4
    static let maxCutSegments = 1500
    static let minCutOffsetMM = 1.0

    public static func run(_ doc: Document, preset: ProductPreset? = nil, cutPath: CutPath? = nil,
                           gamut: GamutChecking? = nil) -> PreflightReport {
        let preset = preset ?? ProductCatalog.preset(for: doc)
        var issues: [PreflightIssue] = []
        let leaves = collectLeaves(doc)

        for leaf in leaves {
            checkResolution(leaf, doc, preset, &issues)
            checkThinLine(leaf, &issues)
            checkSmallText(leaf, &issues)
            checkFonts(leaf, &issues)
            if let gamut { checkGamut(leaf, gamut, &issues) }
        }
        if let preset {
            for leaf in leaves {
                checkSafeArea(leaf, preset, &issues)
                checkMugHandle(leaf, preset, &issues)
            }
            if preset.transparentBackground { checkTransparency(doc, &issues) }
            if preset.requiresFullBleed { checkBleed(leaves, preset, &issues) }
            if preset.cutLine != nil { checkCutLine(doc, cutPath, &issues) }
        }
        issues.sort { ($0.severity, $0.check.rawValue, $0.id) < ($1.severity, $1.check.rawValue, $1.id) }
        return PreflightReport(issues: issues)
    }

    // MARK: Walking the layers

    struct Leaf {
        var layer: Layer
        var world: Transform2D
        var bounds: Rect2?                  // on the canvas
        /// Opacity of the layer times that of every group above it.
        var cumulativeOpacity: Double
        /// The group (or the layer itself) that sets the opacity, to name in a fix.
        var transparencySource: UUID?
        var scale: Double { abs(world.determinant).squareRoot() }
    }

    static func collectLeaves(_ doc: Document) -> [Leaf] {
        var out: [Leaf] = []
        func visit(_ layers: [Layer], parent: Transform2D, opacity: Double, source: UUID?) {
            for l in layers where l.isVisible {
                let world = l.transform.then(parent)
                let op = opacity * l.opacity
                let src = l.opacity < 1 ? l.id : source
                if case .group(let kids) = l.content {
                    visit(kids, parent: world, opacity: op, source: src)
                } else {
                    out.append(Leaf(layer: l, world: world, bounds: l.localBounds.map { world.apply($0) },
                                    cumulativeOpacity: op, transparencySource: src))
                }
            }
        }
        visit(doc.layers, parent: .identity, opacity: 1, source: nil)
        return out
    }

    static func isBackgroundLike(_ leaf: Leaf, _ preset: ProductPreset) -> Bool {
        guard let b = leaf.bounds, preset.trimRect.width > 0 else { return false }
        if case .text = leaf.layer.content { return false }
        return b.width * b.height >= 0.5 * preset.trimRect.width * preset.trimRect.height
    }

    static func issue(_ check: PreflightCheck, _ severity: Severity, layer: Layer?, title: String, detail: String,
                      fix: PreflightFix? = nil, fixTitle: String? = nil, suffix: String = "") -> PreflightIssue {
        PreflightIssue(id: "\(check.rawValue):\(layer?.id.uuidString ?? "document")\(suffix)", check: check, severity: severity,
                       layerID: layer?.id, title: title, detail: detail, fix: fix, fixTitle: fixTitle)
    }

    static func fmt(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }

    // MARK: Checks

    static func checkResolution(_ leaf: Leaf, _ doc: Document, _ preset: ProductPreset?, _ out: inout [PreflightIssue]) {
        guard case .image(let img) = leaf.layer.content, let pw = img.pixelWidth, let ph = img.pixelHeight, pw > 0, ph > 0 else { return }
        let sx = (leaf.world.a * leaf.world.a + leaf.world.b * leaf.world.b).squareRoot()
        let sy = (leaf.world.c * leaf.world.c + leaf.world.d * leaf.world.d).squareRoot()
        let wInches = img.size.width * sx / 25.4, hInches = img.size.height * sy / 25.4
        guard wInches > 0, hInches > 0 else { return }
        let effective = min(Double(pw) / wInches, Double(ph) / hInches)
        let target = preset?.dpi ?? doc.dpi
        guard effective < target * 0.999 else { return }
        let severe = effective < target * 0.5
        out.append(issue(.resolution, severe ? .error : .warning, layer: leaf.layer,
                         title: "\"\(leaf.layer.name)\" is low resolution",
                         detail: "At this size the picture prints at \(Int(effective.rounded())) DPI. This product needs \(Int(target)) DPI, so it may look soft or pixelated.",
                         fix: .upscaleImage(layer: leaf.layer.id, targetDPI: target), fixTitle: "Upscale on device"))
    }

    static func checkSafeArea(_ leaf: Leaf, _ preset: ProductPreset, _ out: inout [PreflightIssue]) {
        guard let b = leaf.bounds, !isBackgroundLike(leaf, preset) else { return }
        let safe = preset.safeRect
        let eps = 0.01
        if b.minX >= safe.minX - eps, b.maxX <= safe.maxX + eps, b.minY >= safe.minY - eps, b.maxY <= safe.maxY + eps { return }
        var fix: PreflightFix?
        if b.width <= safe.width + eps, b.height <= safe.height + eps {
            var dx = 0.0, dy = 0.0
            if b.minX < safe.minX { dx = safe.minX - b.minX } else if b.maxX > safe.maxX { dx = safe.maxX - b.maxX }
            if b.minY < safe.minY { dy = safe.minY - b.minY } else if b.maxY > safe.maxY { dy = safe.maxY - b.maxY }
            fix = .move(layer: leaf.layer.id, dx: dx, dy: dy)
        }
        out.append(issue(.safeArea, .warning, layer: leaf.layer, title: "\"\(leaf.layer.name)\" is outside the safe area",
                         detail: "Keep important things at least \(fmt(preset.safeInset)) mm inside the edge. Anything closer can be cut off or lost in trimming.",
                         fix: fix, fixTitle: fix == nil ? nil : "Move inside"))
    }

    static func checkBleed(_ leaves: [Leaf], _ preset: ProductPreset, _ out: inout [PreflightIssue]) {
        let canvas = preset.canvasRect
        let eps = 0.05
        func covers(_ b: Rect2) -> Bool {
            b.minX <= canvas.minX + eps && b.minY <= canvas.minY + eps && b.maxX >= canvas.maxX - eps && b.maxY >= canvas.maxY - eps
        }
        let backdrops = leaves.filter {
            switch $0.layer.content {
            case .image: return true
            case .shape(let s): return s.fill != nil
            default: return false
            }
        }
        if backdrops.contains(where: { $0.bounds.map(covers) ?? false }) { return }
        // A picture or shape that nearly covers the canvas can simply be stretched to the edge.
        let candidate = backdrops.first { l in
            guard let b = l.bounds else { return false }
            return b.width * b.height >= 0.6 * canvas.width * canvas.height
        }
        out.append(issue(.bleed, .error, layer: candidate?.layer, title: "The artwork does not reach the bleed edge",
                         detail: "This product is printed over its whole surface. Extend the background to the outer edge (\(fmt(preset.bleed)) mm past the trim) so no white strip shows after trimming.",
                         fix: candidate.map { .extendToBleed(layer: $0.layer.id) }, fixTitle: candidate == nil ? nil : "Extend background"))
    }

    static func checkThinLine(_ leaf: Leaf, _ out: inout [PreflightIssue]) {
        let width: Double?
        switch leaf.layer.content {
        case .shape(let s): width = s.stroke?.width
        case .text(let t): width = t.style.stroke?.width
        default: width = nil
        }
        guard let w = width, w > 0, w * leaf.scale < minLineMM - 1e-9 else { return }
        out.append(issue(.thinLine, .warning, layer: leaf.layer, title: "A line in \"\(leaf.layer.name)\" is very thin",
                         detail: "It is \(fmt(w * leaf.scale, 2)) mm thick. Lines under \(fmt(minLineMM, 2)) mm can disappear when printed.",
                         fix: .thickenStroke(layer: leaf.layer.id, to: minLineMM / max(leaf.scale, 1e-9)), fixTitle: "Thicken"))
    }

    static func checkSmallText(_ leaf: Leaf, _ out: inout [PreflightIssue]) {
        guard case .text(let t) = leaf.layer.content, !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let points = t.style.size * leaf.scale * pointsPerMM
        guard points < minTextPoints - 1e-9 else { return }
        let wanted = minTextPoints / pointsPerMM / max(leaf.scale, 1e-9)
        out.append(issue(.smallText, .warning, layer: leaf.layer, title: "The text \"\(preview(t.text))\" is very small",
                         detail: "It prints at about \(fmt(points)) pt. Text under \(Int(minTextPoints)) pt is hard to read, especially on fabric.",
                         fix: .enlargeText(layer: leaf.layer.id, size: wanted), fixTitle: "Enlarge"))
    }

    static func checkFonts(_ leaf: Leaf, _ out: inout [PreflightIssue]) {
        guard case .text(let t) = leaf.layer.content, !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              t.outline.elements.isEmpty else { return }
        out.append(issue(.fonts, .error, layer: leaf.layer, title: "The text \"\(preview(t.text))\" has no shape",
                         detail: "The font could not be found or the text could not be laid out, so nothing would print. Choose another font."))
    }

    static func checkTransparency(_ doc: Document, _ out: inout [PreflightIssue]) {
        var reported = Set<UUID>()
        func report(_ layer: Layer, _ why: String, fix: PreflightFix) {
            guard reported.insert(layer.id).inserted else { return }
            out.append(issue(.semiTransparency, .warning, layer: layer, title: "\"\(layer.name)\" is partly transparent",
                             detail: "\(why) Direct-to-film and sticker printing handle partial transparency poorly, so it can print as a speckled or washed-out patch. Make it solid or flatten it.",
                             fix: fix, fixTitle: "Make solid"))
        }
        func visit(_ layers: [Layer]) {
            for l in layers where l.isVisible {
                if l.opacity < 1 { report(l, "Its opacity is \(Int((l.opacity * 100).rounded()))%.", fix: .removeTransparency(layer: l.id)) }
                if l.blendMode != .normal { report(l, "It uses the \(l.blendMode.rawValue) blend mode.", fix: .removeTransparency(layer: l.id)) }
                switch l.content {
                case .shape(let s):
                    if let f = s.fill, f.a < 1 { report(l, "Its fill is \(Int((f.a * 100).rounded()))% opaque.", fix: .removeTransparency(layer: l.id)) }
                    if let st = s.stroke, st.color.a < 1 { report(l, "Its outline is partly transparent.", fix: .removeTransparency(layer: l.id)) }
                case .text(let t):
                    if t.style.fill.a < 1 { report(l, "The text colour is partly transparent.", fix: .removeTransparency(layer: l.id)) }
                case .group(let kids): visit(kids)
                case .image: break
                }
            }
        }
        visit(doc.layers)
    }

    static func checkGamut(_ leaf: Leaf, _ gamut: GamutChecking, _ out: inout [PreflightIssue]) {
        func check(_ color: RGBA, _ target: ColorTarget, _ what: String) {
            guard !gamut.isInGamut(color) else { return }
            let near = gamut.nearestInGamut(color)
            out.append(issue(.gamut, .warning, layer: leaf.layer, title: "A colour in \"\(leaf.layer.name)\" cannot be printed exactly",
                             detail: "The \(what) is more vivid than CMYK ink can reproduce, so it will print duller than on screen. The closest printable colour is shown in the soft proof.",
                             fix: .replaceColor(layer: leaf.layer.id, target: target, with: near), fixTitle: "Use closest colour",
                             suffix: ":\(target == .fill ? "fill" : "stroke")"))
        }
        switch leaf.layer.content {
        case .shape(let s):
            if let f = s.fill { check(f, .fill, "fill colour") }
            if let st = s.stroke { check(st.color, .stroke, "outline colour") }
        case .text(let t):
            check(t.style.fill, .fill, "text colour")
        default: break
        }
    }

    static func checkCutLine(_ doc: Document, _ path: CutPath?, _ out: inout [PreflightIssue]) {
        guard !doc.layers.isEmpty else { return }
        if let c = doc.cutLine, c.offset < minCutOffsetMM - 1e-9 {
            out.append(issue(.cutLine, .warning, layer: nil, title: "The cut line is very close to the artwork",
                             detail: "It sits \(fmt(c.offset, 2)) mm from the edge. Cutters are not that exact, so the blade can nick the design. \(fmt(minCutOffsetMM)) mm or more is safer.",
                             fix: .setCutOffset(1.5), fixTitle: "Move to 1.5 mm", suffix: ":offset"))
        }
        guard let path else { return }
        // Checking a very complex path for crossings is slow, and it is reported as too complex anyway.
        if path.segmentCount <= maxCutSegments, path.hasSelfIntersections() {
            out.append(issue(.cutLine, .error, layer: nil, title: "The cut line crosses itself",
                             detail: "A cutter cannot follow a path that crosses itself. Increase the smoothing or the offset.",
                             fix: .simplifyCutLine, fixTitle: "Smooth the cut line", suffix: ":crossing"))
        }
        if path.segmentCount > maxCutSegments {
            out.append(issue(.cutLine, .warning, layer: nil, title: "The cut line is very complex",
                             detail: "It has \(path.segmentCount) curve segments. Many cutters slow down or stutter on that much detail. Simplifying keeps the shape and cuts faster.",
                             fix: .simplifyCutLine, fixTitle: "Simplify", suffix: ":complex"))
        }
    }

    /// Keeps things out of the product's restricted zones: the handle on a mug, the camera on a case.
    static func checkMugHandle(_ leaf: Leaf, _ preset: ProductPreset, _ out: inout [PreflightIssue]) {
        guard !preset.restrictedZones.isEmpty, let b = leaf.bounds, !isBackgroundLike(leaf, preset) else { return }
        guard let hit = preset.restrictedZones.first(where: { overlap($0, b) > 1e-6 }) else { return }
        var fix: PreflightFix?
        let sorted = preset.restrictedZones.sorted { $0.minX < $1.minX }
        let canvas = preset.canvasRect
        if sorted.count >= 2 {
            // Several zones (the two ends of a mug wrap): slide into the free band between them.
            let free0 = sorted[0].maxX, free1 = sorted[sorted.count - 1].minX
            if b.width <= free1 - free0 {
                var dx = 0.0
                if b.minX < free0 { dx = free0 - b.minX } else if b.maxX > free1 { dx = free1 - b.maxX }
                if dx != 0 { fix = .move(layer: leaf.layer.id, dx: dx, dy: 0) }
            }
        } else {
            // One zone (a camera): move just below it, or just beside it, if the layer still fits on the canvas.
            let gap = 2.0
            let dy = hit.maxY - b.minY + gap
            let dx = hit.maxX - b.minX + gap
            if b.maxY + dy <= canvas.maxY - preset.bleed { fix = .move(layer: leaf.layer.id, dx: 0, dy: dy) }
            else if b.maxX + dx <= canvas.maxX - preset.bleed, hit.width < canvas.width * 0.9 { fix = .move(layer: leaf.layer.id, dx: dx, dy: 0) }
        }
        out.append(issue(.mugHandle, .warning, layer: leaf.layer,
                         title: "\"\(leaf.layer.name)\" is where the \(preset.restrictedZoneName) goes",
                         detail: preset.restrictedZoneAdvice,
                         fix: fix, fixTitle: fix == nil ? nil : "Move it out of the way"))
    }

    static func overlap(_ a: Rect2, _ b: Rect2) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX), h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return w > 0 && h > 0 ? w * h : 0
    }

    static func preview(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > 24 ? String(one.prefix(24)) + "…" : one
    }
}
