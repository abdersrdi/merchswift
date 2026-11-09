import CoreGraphics
import DocumentModel
import Editor
import Export
import Foundation
import ImageIO
import ImageTools

/// The edits offered on a picture. Each one makes a new picture and points the layer at it.
enum PhotoEdit: String, CaseIterable, Identifiable {
    case removeBackground, refineEdge, stickerBorder, shadow, sharpen, vintage, halftone, distress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .removeBackground: return "Remove background"
        case .refineEdge: return "Clean the edge"
        case .stickerBorder: return "Sticker border"
        case .shadow: return "Drop shadow"
        case .sharpen: return "Sharpen"
        case .vintage: return "Vintage look"
        case .halftone: return "Halftone dots"
        case .distress: return "Worn print"
        }
    }

    var icon: String {
        switch self {
        case .removeBackground: return "person.crop.rectangle"
        case .refineEdge: return "scissors"
        case .stickerBorder: return "square.dashed"
        case .shadow: return "shadow"
        case .sharpen: return "triangle"
        case .vintage: return "camera.filters"
        case .halftone: return "circle.grid.3x3"
        case .distress: return "sparkles"
        }
    }

    /// Runs the edit. `mmPerPixel` turns millimetres into pixels so a 2 mm border is 2 mm whatever the picture's resolution.
    /// `padding` is how many pixels were added on every side, so the layer can be moved and resized to match.
    func run(on image: RGBAImage, mmPerPixel: Double) throws -> (image: RGBAImage, padding: Int) {
        let px = { (mm: Double) in mm / max(mmPerPixel, 0.0001) }
        switch self {
        case .removeBackground:
            let cut = try VisionCutout.removeBackground(from: image)
            return (AlphaTools.refine(cut, RefineOptions(feather: 1, shift: -0.5, harden: false, defringe: true)), 0)
        case .refineEdge:
            return (AlphaTools.refine(image, RefineOptions(feather: 1, shift: -1, harden: true, defringe: true)), 0)
        case .stickerBorder:
            return AlphaTools.border(image, thickness: px(2), color: .white)
        case .shadow:
            return AlphaTools.dropShadow(image, dx: px(0.8), dy: px(1.2), blur: px(1.2), opacity: 0.5)
        case .sharpen:
            return (Filters.unsharpMask(image, radius: px(0.25), amount: 0.6), 0)
        case .vintage:
            return (Filters.vintageTone(image, fade: 0.3, warmth: 0.4), 0)
        case .halftone:
            return (Halftone.apply(image, HalftoneOptions(cell: px(0.8))), 0)
        case .distress:
            return (Distress.apply(image, DistressOptions(scale: px(2))), 0)
        }
    }
}

/// Brings pictures into the design and applies the edits to the selected one.
@MainActor
final class PhotoEditor: ObservableObject {
    @Published private(set) var busy = false
    @Published var message: String?

    private let model: EditorModel
    private let assets = AssetStore.shared
    /// The longest side kept on import; bigger pictures are scaled down so editing stays fast and memory stays small.
    private let maxSide = 4096

    init(model: EditorModel) { self.model = model }

    /// The selected layer, when it is a single picture.
    var selectedImageLayer: (id: UUID, content: ImageContent)? {
        guard model.tools.selection.count == 1, let id = model.tools.selection.first,
              let layer = model.store.document.layer(id: id), case .image(let c) = layer.content else { return nil }
        return (id, c)
    }

    // MARK: Import

    /// Adds a picture from file data (photo library or Files), centred on the design and sized to fit.
    func importPicture(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { message = "That file is not a picture."; return }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let rgba = VisionCutout.makeRGBA(cg) else {
            message = "This picture could not be opened."; return
        }
        let doc = model.store.document
        let fitW = doc.size.width * 0.6, fitH = doc.size.height * 0.6
        let scale = min(fitW / Double(rgba.width), fitH / Double(rgba.height))
        let size = Size2(Double(rgba.width) * scale, Double(rgba.height) * scale)
        let id = assets.add(rgba)
        let layer = Layer(name: "Picture", content: .image(ImageContent(assetID: id, size: size, pixelWidth: rgba.width, pixelHeight: rgba.height)),
                          transform: .translation((doc.size.width - size.width) / 2, (doc.size.height - size.height) / 2))
        model.store.perform("Add picture") { d in _ = d.insert(layer) }
        model.tools.select([layer.id])
        message = nil
    }

    // MARK: Edits

    func apply(_ edit: PhotoEdit) {
        guard !busy, let target = selectedImageLayer, let source = assets.pixels(for: target.content.assetID) else {
            message = "Select a picture first."; return
        }
        busy = true
        message = nil
        let mmPerPixel = target.content.size.width / Double(source.width)
        Task.detached(priority: .userInitiated) {
            do {
                let result = try edit.run(on: source, mmPerPixel: mmPerPixel)
                await MainActor.run { self.finish(edit, target.id, target.content, result.image, result.padding, mmPerPixel) }
            } catch CutoutError.noSubject {
                await MainActor.run { self.busy = false; self.message = "No subject found. Try a picture with a clear person, animal or object." }
            } catch {
                await MainActor.run { self.busy = false; self.message = "\(edit.title) did not work: \(error)" }
            }
        }
    }

    private func finish(_ edit: PhotoEdit, _ id: UUID, _ old: ImageContent, _ image: RGBAImage, _ padding: Int, _ mmPerPixel: Double) {
        defer { busy = false }
        let newID = assets.add(image)
        let size = Size2(Double(image.width) * mmPerPixel, Double(image.height) * mmPerPixel)
        let shift = Double(padding) * mmPerPixel
        model.store.perform(edit.title) { doc in
            _ = doc.update(id: id) { layer in
                layer.content = .image(ImageContent(assetID: newID, size: size, pixelWidth: image.width, pixelHeight: image.height))
                if padding > 0 { layer.transform = Transform2D.translation(-shift, -shift).then(layer.transform) }
            }
        }
    }
}
