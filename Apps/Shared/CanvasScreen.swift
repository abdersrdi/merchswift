import DocumentModel
import Editor
import ExportKit
import Products
import Renderer
import SwiftUI
import Typography

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

    let shaper = CoreTextShaper()
    let pipeline: ExportPipeline

    /// Starts a blank design for a product, or sets one up around what is already on the canvas.
    func newDocument(for preset: ProductPreset) {
        tools.select([])
        store.reset(to: preset.makeDocument())
    }

    init(document: Document, assets: AssetProvider? = nil) {
        pipeline = ExportPipeline(assets: assets)
        FontLibrary.shared.registerBundledFonts()
        var doc = document
        doc.reshapeAllText(using: shaper)
        store = DocumentStore(document: doc)
        tools = ToolController(store: store)
        tools.textShaper = shaper
        tokens.append(tools.observe { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } })
        tokens.append(store.observe { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } })
    }
}

struct CanvasScreen: View {
    private let assets = AssetStore.shared
    @StateObject private var controller = CanvasController()
    @StateObject private var model: EditorModel
    @StateObject private var session: DesignSession
    @State private var showPrint = false
    @State private var showDesigns = false
    @State private var showPaywall = false
    @ObservedObject private var policy = WatermarkPolicy.shared
    @State private var stats = CanvasStats()
    @State private var showInspector = true

    private var tools: ToolController { model.tools }
    private var store: DocumentStore { model.store }

    init() {
        // A real first launch starts with a blank T-shirt design. The 60-layer test design is for development builds only.
        #if DEBUG
        let start = DemoDocument.make()
        #else
        let start = ProductCatalog.tshirtFront.makeDocument(title: "My design")
        #endif
        let m = EditorModel(document: start, assets: AssetStore.shared)
        _model = StateObject(wrappedValue: m)
        _session = StateObject(wrappedValue: DesignSession(model: m))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CanvasHost(tools: tools, assets: assets, controller: controller) { stats = $0 }
                .ignoresSafeArea(edges: .bottom)
            #if DEBUG
            hud.padding(12)
            #endif
        }
        .overlay(alignment: .bottom) { toolbar.padding(.bottom, 14) }
        .sheet(isPresented: $showPrint) { PrintPanel(model: model) }
        .sheet(isPresented: $showDesigns) { DesignsView(session: session, model: model) }
        .sheet(isPresented: $showPaywall) { PaywallView() }
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
                    Label("Text", systemImage: "textformat").tag(Tool.text)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .frame(width: 150)

                if tools.tool == .pen {
                    Button { tools.finishPath() } label: { Label("Finish path", systemImage: "checkmark") }
                }

                Menu {
                    ForEach(ProductCatalog.all) { p in Button(p.name) { Task { await session.newDesign(for: p) } } }
                } label: { Label("New design", systemImage: "doc.badge.plus") }
                Button { showDesigns = true } label: { Label("My designs", systemImage: "folder") }
                Button { showPaywall = true } label: { Label(policy.isPro ? "Pro" : "Go Pro", systemImage: policy.isPro ? "star.fill" : "star") }
                PhotoMenu(model: model)
                Button { showPrint = true } label: { Label("Print checks and export", systemImage: "printer") }

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
            if let text = tools.selectedText { TextInspector(tools: tools, id: text.id, content: text.content) }
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

/// Text settings: the words, the font, and the typographic controls.
struct TextInspector: View {
    let tools: ToolController
    let id: UUID
    let content: TextContent

    private let optional: [(String, String)] = [("dlig", "Discretionary ligatures"), ("swsh", "Swashes"), ("smcp", "Small caps"),
                                                 ("ss01", "Style set 1"), ("tnum", "Tabular figures")]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(get: { content.text }, set: { v in tools.updateText(id) { $0.text = v } }))
                .font(.body)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))

            Picker("Font", selection: Binding(get: { content.style.family }, set: { v in tools.updateText(id) { $0.style.family = v } })) {
                ForEach(FontLibrary.shared.families, id: \.name) { f in
                    Text(f.supportsArabic ? "\(f.name)  ع" : f.name).tag(f.name)
                }
            }
            .pickerStyle(.menu)

            slider("Weight", value: content.style.weight, range: 100...900) { v in tools.updateText(id) { $0.style.weight = (v / 100).rounded() * 100 } }
            slider("Size", value: content.style.size, range: 2...120) { v in tools.updateText(id) { $0.style.size = v } }
            slider("Spacing", value: content.style.tracking, range: -50...400) { v in tools.updateText(id) { $0.style.tracking = v } }
            slider("Lines", value: content.style.lineSpacing, range: 0.6...2.5) { v in tools.updateText(id) { $0.style.lineSpacing = v } }
            slider("Bend", value: bend, range: -180...180) { v in
                tools.updateText(id) { $0.style.curve = abs(v) < 1 ? nil : .arc(degrees: v) }
            }

            Picker("Align", selection: Binding(get: { content.style.alignment }, set: { v in tools.updateText(id) { $0.style.alignment = v } })) {
                Text("Start").tag(DocumentModel.TextAlignment.start); Text("Centre").tag(DocumentModel.TextAlignment.center)
                Text("End").tag(DocumentModel.TextAlignment.end); Text("Justify").tag(DocumentModel.TextAlignment.justified)
            }
            .pickerStyle(.segmented)

            Picker("Direction", selection: Binding(get: { content.style.direction }, set: { v in tools.updateText(id) { $0.style.direction = v } })) {
                Text("Auto").tag(TextDirection.auto); Text("RTL").tag(TextDirection.rightToLeft); Text("LTR").tag(TextDirection.leftToRight)
            }
            .pickerStyle(.segmented)

            Toggle("Italic", isOn: Binding(get: { content.style.italic }, set: { v in tools.updateText(id) { $0.style.italic = v } }))
            ForEach(optional, id: \.0) { tag, title in
                Toggle(title, isOn: Binding(get: { content.style.features.contains(FontFeature(tag)) }, set: { on in
                    tools.updateText(id) { t in
                        t.style.features.removeAll { $0.tag == tag }
                        if on { t.style.features.append(FontFeature(tag)) }
                    }
                }))
            }
        }
        .font(.caption)
    }

    private var bend: Double {
        if case .arc(let d)? = content.style.curve { return d }
        return 0
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
        }
    }
}

struct RootView: View {
    var body: some View {
        #if DEBUG
        TabView {
            CanvasScreen()
                .tabItem { Label("Canvas", systemImage: "square.on.square.dashed") }
            ProofView()
                .tabItem { Label("Cut proof", systemImage: "scissors") }
        }
        #else
        CanvasScreen()
        #endif
    }
}
