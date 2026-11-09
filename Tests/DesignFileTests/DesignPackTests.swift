import CutLine
import DocumentModel
import XCTest
@testable import DesignFile

final class DesignPackTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("designpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])

    private func design(_ title: String = "Pack me") -> Document {
        let pic = Layer(name: "pic", content: .image(ImageContent(assetID: "p1", size: Size2(20, 20), pixelWidth: 200, pixelHeight: 200)))
        return Document(title: title, size: Size2(100, 100), presetID: "tee-front", layers: [pic])
    }

    /// Builds pack data by hand, to try names the app itself would never write.
    private func pack(_ files: [(String, Data)]) -> Data {
        var out = Data("MSWPACK1".utf8)
        for (name, data) in files {
            let n = Data(name.utf8)
            out.append(contentsOf: [0, 0, UInt8(n.count >> 8), UInt8(n.count & 255)]); out.append(n)
            var len = UInt64(data.count); var be = [UInt8](repeating: 0, count: 8)
            for i in (0..<8).reversed() { be[i] = UInt8(len & 255); len >>= 8 }
            out.append(contentsOf: be); out.append(data)
        }
        return out
    }

    func testExportThenImportGivesTheSameDesign() throws {
        let lib = DesignLibrary(root: root.appendingPathComponent("a"))
        try lib.save(design(), assets: ["p1": png], thumbnail: png + [9], id: "one")
        let data = try lib.exportData(id: "one")

        let other = DesignLibrary(root: root.appendingPathComponent("b"))           // another device
        let id = try other.importData(data)
        XCTAssertNotEqual(id, "one")
        let back = try other.load(id: id)
        XCTAssertEqual(back.document, design())
        XCTAssertEqual(back.assets["p1"], png)
        XCTAssertNotNil(other.entries().first { $0.id == id }?.thumbnailURL)
        XCTAssertEqual(other.entries().map(\.title), ["Pack me"])
    }

    func testImportingTwiceMakesTwoDesigns() throws {
        let lib = DesignLibrary(root: root)
        try lib.save(design(), assets: ["p1": png], id: "one")
        let data = try lib.exportData(id: "one")
        _ = try lib.importData(data)
        _ = try lib.importData(data)
        XCTAssertEqual(lib.entries().count, 3)
    }

    func testPacksThatAreNotPacksAreRefused() {
        XCTAssertThrowsError(try DesignPack.files(in: Data("hello".utf8))) { XCTAssertEqual($0 as? DesignPackError, .notAPack) }
        XCTAssertThrowsError(try DesignPack.files(in: Data())) { XCTAssertEqual($0 as? DesignPackError, .notAPack) }
        XCTAssertThrowsError(try DesignPack.files(in: pack([("assets/a.png", png)]))) { XCTAssertEqual($0 as? DesignPackError, .notAPack) }   // no design.json
    }

    func testCutOffPacksAreRefused() throws {
        let lib = DesignLibrary(root: root)
        try lib.save(design(), assets: ["p1": png], id: "one")
        let data = try lib.exportData(id: "one")
        XCTAssertThrowsError(try DesignPack.files(in: data.dropLast(3))) { XCTAssertEqual($0 as? DesignPackError, .truncated) }
        XCTAssertThrowsError(try lib.importData(Data(data.prefix(data.count / 2))))
        XCTAssertEqual(lib.entries().count, 1, "a failed import leaves nothing behind")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["one.merchswift"])
    }

    func testNamesThatCouldEscapeTheFolderAreRefused() {
        for bad in ["../evil.png", "assets/../evil.png", "/etc/passwd", "assets/.hidden.png", "assets/a/b.png", "other.txt", "assets/x.exe"] {
            XCTAssertThrowsError(try DesignPack.files(in: pack([("design.json", Data("{}".utf8)), (bad, png)])), bad) { error in
                if case .unsafeName? = error as? DesignPackError {} else { XCTFail("\(bad): expected unsafeName, got \(error)") }
            }
        }
    }

    func testAPackWithAnUnreadableDescriptionIsNotImported() throws {
        let lib = DesignLibrary(root: root)
        XCTAssertThrowsError(try lib.importData(pack([("design.json", Data("{ nope".utf8))])))
        XCTAssertEqual(lib.entries().count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testThumbnailIsCarriedOverWhenNotGivenAgain() throws {
        let lib = DesignLibrary(root: root)
        try lib.save(design(), assets: ["p1": png], thumbnail: png + [5], id: "one")
        try lib.save(design("Renamed"), assets: [:], id: "one")
        let entry = try XCTUnwrap(lib.entries().first)
        XCTAssertEqual(entry.title, "Renamed")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(entry.thumbnailURL)), png + [5])
    }
}
