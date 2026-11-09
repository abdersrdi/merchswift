import CutLine
import DocumentModel
import XCTest
@testable import DesignFile

final class DesignFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("designfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func picture(_ id: String, at x: Double = 0) -> Layer {
        Layer(name: "Picture \(id)", content: .image(ImageContent(assetID: id, size: Size2(40, 30), pixelWidth: 400, pixelHeight: 300)),
              transform: .translation(x, 5))
    }

    private func design(title: String = "My tee") -> Document {
        let shape = Layer(name: "Box", content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: 10, height: 10)), fill: RGBA(0.2, 0.4, 0.6))))
        let group = Layer(name: "Group", content: .group([picture("inside")]), transform: .translation(3, 4))
        return Document(title: title, size: Size2(300, 400), dpi: 300, presetID: "tee-front", layers: [picture("top"), shape, group])
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    func testReferencedPicturesIncludeThoseInsideGroupsOnceEach() {
        var d = design()
        d.layers.append(picture("top", at: 50))               // the same picture used twice
        XCTAssertEqual(DesignPackage.assetIDs(in: d), ["inside", "top"])
    }

    func testRoundTripKeepsTheDesignAndPictures() throws {
        let url = root.appendingPathComponent("a.merchswift")
        let d = design()
        try DesignPackage.write(d, assets: ["top": png, "inside": png + [9]], to: url)
        let back = try DesignPackage.read(from: url)
        XCTAssertEqual(back.document, d)
        XCTAssertEqual(back.assets["top"], png)
        XCTAssertEqual(back.assets["inside"], png + [9])
        XCTAssertEqual(back.assets.count, 2)
    }

    func testOnlyUsedPicturesAreWritten() throws {
        let url = root.appendingPathComponent("a.merchswift")
        try DesignPackage.write(design(), assets: ["top": png, "inside": png, "unused": png], to: url)
        XCTAssertNil(try DesignPackage.read(from: url).assets["unused"])
    }

    func testUnusualPictureIDsSurvive() throws {
        let url = root.appendingPathComponent("a.merchswift")
        let odd = "a/b c..d ع%"
        let d = Document(title: "x", size: Size2(10, 10), layers: [picture(odd)])
        try DesignPackage.write(d, assets: [odd: png], to: url)
        XCTAssertEqual(try DesignPackage.read(from: url).assets[odd], png)
    }

    func testAMissingPictureFileStillOpensTheDesign() throws {
        let url = root.appendingPathComponent("a.merchswift")
        try DesignPackage.write(design(), assets: ["top": png], to: url)           // "inside" has no data
        let back = try DesignPackage.read(from: url)
        XCTAssertEqual(back.document, design())
        XCTAssertNil(back.assets["inside"])
    }

    func testPicturesNotGivenAgainAreCarriedOverFromTheEarlierSave() throws {
        let url = root.appendingPathComponent("a.merchswift")
        try DesignPackage.write(design(), assets: ["top": png, "inside": png + [1]], to: url)
        try DesignPackage.write(design(title: "renamed"), assets: [:], to: url)      // nothing new to encode
        let back = try DesignPackage.read(from: url)
        XCTAssertEqual(back.document.title, "renamed")
        XCTAssertEqual(back.assets["top"], png)
        XCTAssertEqual(back.assets["inside"], png + [1])
    }

    func testAPictureNoLongerUsedIsDroppedFromTheFile() throws {
        let url = root.appendingPathComponent("a.merchswift")
        try DesignPackage.write(design(), assets: ["top": png, "inside": png], to: url)
        var smaller = design()
        smaller.layers.removeLast()                                                   // the group with "inside"
        try DesignPackage.write(smaller, assets: [:], to: url)
        XCTAssertEqual(Set(try DesignPackage.read(from: url).assets.keys), ["top"])
    }

    func testOverwritingReplacesAndLeavesNoLeftovers() throws {
        let url = root.appendingPathComponent("a.merchswift")
        try DesignPackage.write(design(title: "first"), assets: ["top": png], to: url)
        try DesignPackage.write(design(title: "second"), assets: ["top": png + [7]], to: url)
        let back = try DesignPackage.read(from: url)
        XCTAssertEqual(back.document.title, "second")
        XCTAssertEqual(back.assets["top"], png + [7])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["a.merchswift"])
    }

    func testInfoReadsTheTitleWithoutTheWholeDesign() throws {
        let url = root.appendingPathComponent("a.merchswift")
        try DesignPackage.write(design(title: "Cat sticker"), assets: [:], modified: Date(timeIntervalSince1970: 1_700_000_000), to: url)
        let info = try DesignPackage.info(at: url)
        XCTAssertEqual(info.title, "Cat sticker")
        XCTAssertEqual(info.presetID, "tee-front")
        XCTAssertEqual(info.format, DesignPackage.formatVersion)
        XCTAssertEqual(info.modified.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func testNotADesignAndDamagedAndTooNew() throws {
        let empty = root.appendingPathComponent("empty.merchswift")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try DesignPackage.info(at: empty)) { XCTAssertEqual($0 as? DesignFileError, .notADesign) }

        let bad = root.appendingPathComponent("bad.merchswift")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: bad.appendingPathComponent("design.json"))
        XCTAssertThrowsError(try DesignPackage.read(from: bad)) {
            if case .corrupt? = $0 as? DesignFileError {} else { XCTFail("expected corrupt, got \($0)") }
        }

        let future = root.appendingPathComponent("future.merchswift")
        try DesignPackage.write(design(), assets: [:], to: future)
        let file = future.appendingPathComponent("design.json")
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\"format\":1", with: "\"format\":99")
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DesignPackage.read(from: future)) { XCTAssertEqual($0 as? DesignFileError, .tooNew(version: 99)) }
    }

    func testLibraryListsNewestFirstSkipsBadFilesAndDeletes() throws {
        let lib = DesignLibrary(root: root)
        try lib.save(design(title: "old"), assets: [:], id: "one", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try lib.save(design(title: "new"), assets: [:], id: "two", modified: Date(timeIntervalSince1970: 1_800_000_000))
        try FileManager.default.createDirectory(at: lib.url(for: "broken"), withIntermediateDirectories: true)   // no design.json
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))

        XCTAssertEqual(lib.entries().map(\.title), ["new", "old"])
        XCTAssertEqual(lib.entries().map(\.id), ["two", "one"])
        XCTAssertTrue(lib.exists(id: "one"))
        try lib.delete(id: "one")
        XCTAssertFalse(lib.exists(id: "one"))
        XCTAssertEqual(lib.entries().map(\.id), ["two"])
        XCTAssertEqual(try lib.load(id: "two").document.title, "new")
    }

    func testEmptyLibraryFolderThatDoesNotExistYet() {
        let lib = DesignLibrary(root: root.appendingPathComponent("nope"))
        XCTAssertEqual(lib.entries(), [])
    }
}
