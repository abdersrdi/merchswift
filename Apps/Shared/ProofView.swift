import CoreGraphics
import CutLine
import Export
import SwiftUI

/// M0/M1 proof screen: draws a sample sticker, builds its cut line on the device, and writes the
/// PDF (with the CutContour spot colour), SVG and DXF files so they can be opened in a cutter's software.
struct ProofView: View {
    @StateObject private var model = ProofModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("MerchSwift")
                    .font(.largeTitle.weight(.bold))
                Text("Cut line and PDF proof")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.5, opacity: 0.12))
                    if let image = model.preview {
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFit().padding(16)
                        if let cut = model.cutPath, let size = model.previewSize {
                            CutOverlay(path: cut, size: size).padding(16)
                        }
                    } else {
                        ProgressView()
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 420)
                .accessibilityLabel("Sticker preview with cut line")

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.status).font(.callout.monospacedDigit())
                    Text(StickerPDF.pdfioVersion).font(.footnote).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Run again") { model.run() }
                        .buttonStyle(.borderedProminent)
                    ForEach(model.files, id: \.self) { url in
                        ShareLink(item: url) { Label(url.pathExtension.uppercased(), systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if model.preview == nil { model.run() } }
    }
}

private struct CutOverlay: View {
    let path: CutPath
    let size: CGSize

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / size.width, geo.size.height / size.height)
            let dx = (geo.size.width - size.width * scale) / 2
            let dy = (geo.size.height - size.height * scale) / 2
            Path { p in
                for contour in path.contours {
                    guard let first = contour.segments.first else { continue }
                    func pt(_ q: CutLine.Point) -> CGPoint { CGPoint(x: dx + q.x * scale, y: dy + q.y * scale) }
                    p.move(to: pt(first.p0))
                    for s in contour.segments { p.addCurve(to: pt(s.p3), control1: pt(s.p1), control2: pt(s.p2)) }
                    p.closeSubpath()
                }
            }
            .stroke(Color(red: 1, green: 0, blue: 1), lineWidth: 1.5)
        }
    }
}

@MainActor
final class ProofModel: ObservableObject {
    @Published var preview: CGImage?
    @Published var previewSize: CGSize?
    @Published var cutPath: CutPath?
    @Published var files: [URL] = []
    @Published var status = "Working…"

    func run() {
        status = "Working…"
        Task.detached(priority: .userInitiated) {
            do {
                let started = Date()
                let art = SampleArtwork.make(size: 900)
                let cut = try CutLineGenerator.generate(from: art.alpha, options: CutLineOptions(offset: 36, smoothing: 10))
                let traced = Date()

                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MerchSwiftProof", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let pdf = dir.appendingPathComponent("sticker-cutcontour.pdf")
                try StickerPDF.write(artwork: art, cut: cut, to: pdf, options: StickerPDFOptions(title: "MerchSwift proof sticker", dpi: 300))

                let mm = cut.scaled(by: 25.4 / 300)
                let side = Double(art.width) * 25.4 / 300
                let svg = dir.appendingPathComponent("sticker-cut.svg")
                let dxf = dir.appendingPathComponent("sticker-cut.dxf")
                try SVGWriter.svg(cut: mm, widthMM: side, heightMM: side).write(to: svg, atomically: true, encoding: .utf8)
                try DXFWriter.dxf(cut: mm.flippedY(height: side)).write(to: dxf, atomically: true, encoding: .utf8)
                let info = try StickerPDF.inspect(pdf)
                let done = Date()

                let image = SampleArtwork.cgImage(art)
                let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
                let summary = "Cut line: \(cut.contours.count) path, \(cut.segmentCount) curves, \(ms(started, traced)) ms. "
                    + "PDF \(info.version), \(info.pageCount) page, files in \(ms(traced, done)) ms."
                await MainActor.run {
                    self.preview = image
                    self.previewSize = CGSize(width: art.width, height: art.height)
                    self.cutPath = cut
                    self.files = [pdf, svg, dxf]
                    self.status = summary
                }
            } catch {
                await MainActor.run { self.status = "Failed: \(error)" }
            }
        }
    }
}
