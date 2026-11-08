#if canImport(Metal) && canImport(CoreGraphics)
import CutLine
import DocumentModel
import Editor
import Foundation
import Metal

/// Renders tiles in the background and keeps them as 16-bit float Metal textures. A tile whose content changed
/// stays on screen until its replacement is ready, so editing never flashes blank.
public final class TileCache {
    public let device: MTLDevice
    /// Called on the main thread when a tile finished rendering, so the view can redraw.
    public var onTileReady: (() -> Void)?
    public var maxTiles: Int

    private final class Job { var invalid = false }
    private struct Entry { var texture: MTLTexture; var stale: Bool; var lastUsed: UInt64 }

    private let lock = NSLock()
    private var entries: [TileKey: Entry] = [:]
    private var pending: [TileKey: Job] = [:]
    private var useCounter: UInt64 = 0
    private var document = Document(size: Size2(1, 1))
    private weak var assets: AssetProvider?
    private let queue = DispatchQueue(label: "cc.pdfswift.merchswift.tiles", qos: .userInitiated, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: max(2, ProcessInfo.processInfo.activeProcessorCount - 1))

    public init(device: MTLDevice, maxTiles: Int = 160) {
        self.device = device
        self.maxTiles = maxTiles
    }

    /// Replaces the document. With `dirty` (canvas millimetres) only the tiles it touches go stale; without it, all of them.
    public func setDocument(_ document: Document, assets: AssetProvider?, dirty: Rect2? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.document = document
        self.assets = assets
        for (key, entry) in entries where dirty == nil || TileGrid.rect(of: key).intersects(dirty!) {
            var e = entry; e.stale = true; entries[key] = e
        }
        for (key, job) in pending where dirty == nil || TileGrid.rect(of: key).intersects(dirty!) { job.invalid = true }
    }

    /// The tile's texture if there is one (possibly stale), starting a render when it is missing or stale.
    public func texture(for key: TileKey) -> MTLTexture? {
        lock.lock()
        useCounter += 1
        var result: MTLTexture?
        var needsRender = pending[key] == nil
        if var e = entries[key] {
            e.lastUsed = useCounter
            entries[key] = e
            result = e.texture
            needsRender = needsRender && e.stale
        }
        lock.unlock()
        if needsRender { schedule(key) }
        return result
    }

    /// The cached texture without starting any work, for backdrops from other levels.
    public func peek(_ key: TileKey) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]?.texture
    }

    public func prefetch(_ keys: [TileKey]) {
        for k in keys { _ = texture(for: k) }
    }

    public var cachedCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    /// Blocks until no render is running or `timeout` passes. For tests and export, never the UI thread.
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 20) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if pendingCount == 0 { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        for (_, job) in pending { job.invalid = true }
    }

    // MARK: Rendering

    private func schedule(_ key: TileKey) {
        lock.lock()
        if pending[key] != nil { lock.unlock(); return }
        let job = Job()
        pending[key] = job
        let doc = document
        let assets = self.assets
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.slots.wait()
            let pixels = LayerRasterizer.render(doc, assets: assets, tile: key)
            self.slots.signal()

            var texture: MTLTexture?
            if let pixels { texture = self.makeTexture(pixels) }

            self.lock.lock()
            self.pending[key] = nil
            if let texture, !job.invalid {
                self.useCounter += 1
                self.entries[key] = Entry(texture: texture, stale: false, lastUsed: self.useCounter)
                self.evictIfNeeded()
            }
            self.lock.unlock()
            DispatchQueue.main.async { self.onTileReady?() }
        }
    }

    private func makeTexture(_ pixels: TilePixels) -> MTLTexture? {
        let n = TileGrid.tilePixels
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: n, height: n, mipmapped: false)
        d.usage = .shaderRead
        #if os(macOS)
        d.storageMode = .managed
        #else
        d.storageMode = .shared
        #endif
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        pixels.data.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: n * 8)
        }
        return t
    }

    /// Called with the lock held.
    private func evictIfNeeded() {
        guard entries.count > maxTiles else { return }
        let victims = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(entries.count - maxTiles)
        for (key, _) in victims { entries[key] = nil }
    }
}
#endif
