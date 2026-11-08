// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MerchSwift",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CutLine", targets: ["CutLine"]),
        .library(name: "Export", targets: ["Export"]),
        .library(name: "DocumentModel", targets: ["DocumentModel"]),
        .library(name: "Editor", targets: ["Editor"]),
        .library(name: "Renderer", targets: ["Renderer"]),
        .library(name: "Typography", targets: ["Typography"]),
        .library(name: "Products", targets: ["Products"]),
        .library(name: "Preflight", targets: ["Preflight"]),
    ],
    targets: [
        // PDFio (Apache 2.0) by Michael R Sweet, vendored. Used for PDF/X-4 output.
        .target(
            name: "CPDFio",
            path: "Sources/CPDFio",
            exclude: ["LICENSE", "NOTICE"],
            publicHeadersPath: "include",
            cSettings: [.define("_GNU_SOURCE"), .unsafeFlags(["-UDEBUG"])],  // PDFio prints a trace when DEBUG is set
            linkerSettings: [.linkedLibrary("z")]
        ),
        // Contour tracing, offset, Bezier fitting, SVG and DXF. Foundation only, so it also runs on Linux CI.
        .target(name: "CutLine", path: "Sources/CutLine"),
        .target(name: "Export", dependencies: ["CutLine", "CPDFio"], path: "Sources/Export"),
        .target(name: "DocumentModel", dependencies: ["CutLine"], path: "Sources/DocumentModel"),
        .target(name: "Editor", dependencies: ["DocumentModel", "CutLine"], path: "Sources/Editor"),
        // Metal canvas. Every file is guarded with canImport, so on Linux this target is empty.
        .target(name: "Renderer", dependencies: ["DocumentModel", "Editor", "CutLine"], path: "Sources/Renderer"),
        // Text shaping with Core Text and the bundled SIL OFL fonts. Empty on Linux.
        .target(name: "Typography", dependencies: ["DocumentModel", "Editor", "CutLine"], path: "Sources/Typography",
                resources: [.copy("Fonts")]),
        // Product presets and the print checks. Plain Swift, so they run in Linux CI too.
        .target(name: "Products", dependencies: ["DocumentModel", "CutLine"], path: "Sources/Products"),
        .target(name: "Preflight", dependencies: ["DocumentModel", "CutLine", "Products"], path: "Sources/Preflight"),
        .testTarget(name: "ProductsTests", dependencies: ["Products", "DocumentModel", "CutLine"], path: "Tests/ProductsTests"),
        .testTarget(name: "PreflightTests", dependencies: ["Preflight", "Products", "DocumentModel", "CutLine"], path: "Tests/PreflightTests"),
        .testTarget(name: "TypographyTests", dependencies: ["Typography", "Renderer", "DocumentModel", "Editor", "CutLine"], path: "Tests/TypographyTests"),
        .testTarget(name: "RendererTests", dependencies: ["Renderer", "DocumentModel", "Editor", "CutLine"], path: "Tests/RendererTests"),
        .testTarget(name: "DocumentModelTests", dependencies: ["DocumentModel", "CutLine"], path: "Tests/DocumentModelTests"),
        .testTarget(name: "EditorTests", dependencies: ["Editor", "DocumentModel", "CutLine"], path: "Tests/EditorTests"),
        .testTarget(name: "CutLineTests", dependencies: ["CutLine"], path: "Tests/CutLineTests"),
        .testTarget(name: "ExportTests", dependencies: ["Export", "CutLine", "CPDFio"], path: "Tests/ExportTests"),
    ]
)
