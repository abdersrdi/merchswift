import DocumentModel
import Editor
import Renderer
import SwiftUI

#if os(iOS)
import UIKit

struct CanvasHost: UIViewRepresentable {
    let tools: ToolController
    let assets: AssetProvider
    let controller: CanvasController
    let onStats: (CanvasStats) -> Void

    func makeUIView(context: Context) -> UIView {
        guard let view = CanvasMTKView(tools: tools, assets: assets) else { return unavailable() }
        view.onStats = onStats
        controller.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}

    private func unavailable() -> UIView {
        let label = UILabel()
        label.text = "Metal is not available on this device."
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        return label
    }
}
#elseif os(macOS)
import AppKit

struct CanvasHost: NSViewRepresentable {
    let tools: ToolController
    let assets: AssetProvider
    let controller: CanvasController
    let onStats: (CanvasStats) -> Void

    func makeNSView(context: Context) -> NSView {
        guard let view = CanvasMTKView(tools: tools, assets: assets) else {
            let label = NSTextField(labelWithString: "Metal is not available on this Mac.")
            label.alignment = .center
            return label
        }
        view.onStats = onStats
        controller.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
