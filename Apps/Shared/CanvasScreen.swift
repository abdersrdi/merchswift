import DocumentModel
import Editor
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

/// Lets SwiftUI redraw when the tool controller or the document changes.
final class EditorModel: ObservableObject {
    let store: DocumentStore
    let tools: ToolController
    private var tokens: [UUID] = []

    init(document: Document) {
        store = DocumentStore(document: document)
        tools = ToolController(store: store)
        tokens.append(tools.observe { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } })
        tokens.append(store.observe { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } })
    }
}

struct CanvasScreen: View {
    private let assets = DemoAssets()
    @StateObject private var controller = CanvasController()
    @StateObject private var model = EditorModel(document: DemoDocument.make())
    @State private var stats = CanvasStats()
    @State private var showInspector = true

    private var tools: ToolController { model.tools }
    private var store: DocumentStore { model.store }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CanvasHost(tools: tools, assets: assets, controller: controller) { stats = $0 }
                .ignoresSafeArea(edges: .bottom)
            hud.padding(12)
        }
        .overlay(alignment: .bottom) { toolbar.padding(.bottom, 14) }
        .overlay(alignment: .topTrailing) {
            if showInspector, !tools.selection.isEmpty { Inspector(model: model).padding(12) }
        }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(stats.zoomPercent)%  ·  level \(stats.frame.level)")
            Text("\(store.document.layers.count) layers  ·  \(stats.frame.tilesDrawn) tiles, \(stats.frame.tilesMissing) loading")
            Text(String(format: "encode %.2f ms  ·  %.0f fps", stats.frame.encodeMilliseconds, stats.framesPerSecond))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Picker("Tool", selection: Binding(get: { tools.tool }, set: { tools.tool = $0 })) {
                    Label("Select", systemImage: "cursorarrow").tag(Tool.select)
                    Label("Pen", systemImage: "pencil.tip").tag(Tool.pen)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .frame(width: 110)

                if tools.tool == .pen {
                    Button { tools.finishPath() } label: { Label("Finish path", systemImage: "checkmark") }
                }

                Divider().frame(height: 22)
                Menu {
                    Button("Union") { tools.combineSelection(.union) }
                    Button("Subtract") { tools.combineSelection(.subtract) }
                    Button("Intersect") { tools.combineSelection(.intersect) }
                } label: { Label("Combine", systemImage: "square.on.square.intersection.dashed") }
                    .disabled(!tools.canCombine)
                Button { tools.groupSelection() } label: { Label("Group", systemImage: "rectangle.3.group") }
                    .disabled(tools.selection.count < 2)
                Button { tools.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    .disabled(tools.selection.isEmpty)
                Button(role: .destructive) { tools.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                    .disabled(tools.selection.isEmpty)

                Divider().frame(height: 22)
                Button { store.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!store.canUndo)
                Button { store.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!store.canRedo)

                Divider().frame(height: 22)
                Button { controller.fit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                Button { controller.actualSize() } label: { Label("100%", systemImage: "1.magnifyingglass") }
                Button { controller.zoom(1.5) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                Button { controller.zoom(1 / 1.5) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
            }
            .padding(.horizontal, 12)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 12)
    }
}

/// Position, size, opacity and blend mode of the selection, with millimetre fields that apply on Return.
struct Inspector: View {
    @ObservedObject var model: EditorModel
    @State private var x = ""
    @State private var y = ""
    @State private var w = ""
    @State private var h = ""

    private var tools: ToolController { model.tools }

    var body: some View {
        let ids = tools.selection
        let single = ids.count == 1 ? model.store.document.layer(id: ids[0]) : nil
        VStack(alignment: .leading, spacing: 8) {
            Text(single?.name ?? "\(ids.count) layers").font(.headline)
            if single != nil {
                HStack { field("X", $x); field("Y", $y) }
                HStack { field("W", $w); field("H", $h) }
            }
            if let opacity = single?.opacity ?? ids.first.flatMap({ model.store.document.layer(id: $0)?.opacity }) {
                HStack {
                    Text("Opacity").font(.caption)
                    Slider(value: Binding(get: { opacity }, set: { tools.setOpacity($0) }), in: 0...1)
                }
            }
            Picker("Blend", selection: Binding(get: { single?.blendMode ?? .normal }, set: { tools.setBlendMode($0) })) {
                ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.menu)
        }
        .padding(12)
        .frame(width: 210)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear(perform: load)
        .onChange(of: model.store.revision) { _ in load() }
        .onChange(of: ids) { _ in load() }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).frame(width: 14)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .onSubmit(apply)
        }
    }

    private func load() {
        guard let id = tools.selection.first, tools.selection.count == 1, let b = model.store.document.worldBounds(of: id) else { return }
        x = String(format: "%.2f", b.x); y = String(format: "%.2f", b.y)
        w = String(format: "%.2f", b.width); h = String(format: "%.2f", b.height)
    }

    private func apply() {
        guard let nx = Double(x), let ny = Double(y), let nw = Double(w), let nh = Double(h), nw > 0, nh > 0 else { load(); return }
        tools.setFrame(Rect2(x: nx, y: ny, width: nw, height: nh))
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
