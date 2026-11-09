import CoreGraphics
import Export
import Foundation
import ImageTools
import Renderer

/// The pictures the open design uses. Every edit adds a new picture under a new id and points the layer at it, so the
/// canvas redraws, undo goes back to the earlier picture, and nothing is ever changed in place.
final class AssetStore: AssetProvider {
    /// One store for the app, kept alive here because the canvas only holds a weak reference to its provider.
    static let shared = AssetStore()

    private var pixels: [String: RGBAImage] = [:]
    private var cgImages: [String: CGImage] = [:]
    private let demo = DemoAssets()
    private let lock = NSLock()

    func image(for assetID: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let cg = cgImages[assetID] { return cg }
        if let px = pixels[assetID], let cg = VisionCutout.makeCGImage(px) {
            cgImages[assetID] = cg
            return cg
        }
        return demo.image(for: assetID)
    }

    func pixels(for assetID: String) -> RGBAImage? {
        lock.lock(); defer { lock.unlock() }
        if let px = pixels[assetID] { return px }
        if let cg = demo.image(for: assetID) { return VisionCutout.makeRGBA(cg) }
        return nil
    }

    /// Stores a picture and returns its new id.
    func add(_ image: RGBAImage) -> String {
        let id = UUID().uuidString
        lock.lock(); defer { lock.unlock() }
        pixels[id] = image
        return id
    }
}
