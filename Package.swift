// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MerchSwift",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CutLine", targets: ["CutLine"]),
        .library(name: "Export", targets: ["Export"]),
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
        .testTarget(name: "CutLineTests", dependencies: ["CutLine"], path: "Tests/CutLineTests"),
        .testTarget(name: "ExportTests", dependencies: ["Export", "CutLine", "CPDFio"], path: "Tests/ExportTests"),
    ]
)
