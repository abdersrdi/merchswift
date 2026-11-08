import DocumentModel
import Renderer
import SwiftUI

final class CanvasController: ObservableObject {
    #if canImport(MetalKit)
    weak var view: CanvasMTKView?
    #endif
    func fit() { view?.fit() }
    func actualSize() { view?.zoomToActualSize() }
    func zoom(_ factor: Double) { view?.zoom(by: factor) }
}

struct CanvasScreen: View {
    private let assets = DemoAssets()
    @StateObject private var controller = CanvasController()
    @State private var store = DocumentStore(document: DemoDocument.make())
    @State private var stats = CanvasStats()
    @State private var layerCount = 0
    @State private var revision = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            CanvasHost(store: store, assets: assets, controller: controller) { stats = $0 }
                .ignoresSafeArea(edges: .bottom)
            hud.padding(12)
        }
        .overlay(alignment: .bottom) { toolbar.padding(.bottom, 14) }
        .onAppear { layerCount = store.document.layers.count }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(stats.zoomPercent)%  ·  level \(stats.frame.level)")
            Text("\(layerCount) layers  ·  \(stats.frame.tilesDrawn) tiles drawn, \(stats.frame.tilesMissing) loading")
            Text(String(format: "encode %.2f ms  ·  %.0f fps", stats.frame.encodeMilliseconds, stats.framesPerSecond))
            Text("cache \(stats.cachedTiles)  ·  pending \(stats.pendingTiles)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { controller.fit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
            Button { controller.actualSize() } label: { Label("100%", systemImage: "1.magnifyingglass") }
            Button { controller.zoom(1.5) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
            Button { controller.zoom(1 / 1.5) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
            Divider().frame(height: 22)
            Button {
                store.perform("Add layers") { $0 = DemoDocument.make(extraLayers: 60 + $0.layers.count) }
                layerCount = store.document.layers.count
            } label: { Label("More layers", systemImage: "square.3.layers.3d") }
            Button { store.undo(); layerCount = store.document.layers.count } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!store.canUndo)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            CanvasScreen()
                .tabItem { Label("Canvas", systemImage: "square.on.square.dashed") }
            ProofView()
                .tabItem { Label("Cut proof", systemImage: "scissors") }
        }
    }
}
