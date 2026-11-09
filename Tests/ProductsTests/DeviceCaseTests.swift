import XCTest
import CutLine
import DocumentModel
@testable import Products

final class DeviceCaseTests: XCTestCase {
    private var cases: [ProductPreset] { DeviceCaseCatalog.all }

    func testThirteenPhonesAndThreeTablets() {
        XCTAssertEqual(cases.count, 16)
        XCTAssertEqual(DeviceCaseCatalog.specs.filter { $0.kind == .phone }.count, 13)
        XCTAssertEqual(DeviceCaseCatalog.specs.filter { $0.kind == .tablet }.count, 3)
        XCTAssertEqual(Set(cases.map { $0.id }).count, cases.count, "every id is unique")
        XCTAssertEqual(Set(cases.map { $0.name }).count, cases.count, "and every label is different, so people can tell them apart")
    }

    func testNoBrandOrModelNamesAnywhere() {
        let banned = ["iphone", "ipad", "apple", "galaxy", "samsung", "pixel", "google", "pro max", " air", " mini", "duo"]
        for p in cases {
            for text in [p.id, p.name, p.note, p.restrictedZoneName, p.restrictedZoneAdvice] {
                let t = text.lowercased()
                for word in banned { XCTAssertFalse(t.contains(word), "'\(word)' appears in: \(text)") }
            }
        }
    }

    func testCanvasIsTheDeviceSizePlusThreeMillimetresOfBleed() throws {
        let p = try XCTUnwrap(cases.first { $0.trim == Size2(71.6, 147.6) && $0.name.contains("pill") })
        XCTAssertEqual(p.bleed, 3)
        XCTAssertEqual(p.canvas.width, 77.6, accuracy: 1e-9)
        XCTAssertEqual(p.canvas.height, 153.6, accuracy: 1e-9)
        XCTAssertEqual(p.kind, .deviceCase)
        XCTAssertEqual(p.dpi, 300)
    }

    func testPixelSizesMatchTheSizeTimes300DPI() throws {
        let small = try XCTUnwrap(cases.first { $0.trim == Size2(71.6, 147.6) && $0.name.contains("pill") })
        XCTAssertEqual(DeviceCaseCatalog.pixelSize(of: small).width, 917)
        XCTAssertEqual(DeviceCaseCatalog.pixelSize(of: small).height, 1814)
        let big = try XCTUnwrap(cases.first { $0.trim == Size2(78, 163.4) })
        XCTAssertEqual(DeviceCaseCatalog.pixelSize(of: big).width, 992)
        XCTAssertEqual(DeviceCaseCatalog.pixelSize(of: big).height, 2001)
        let plateau = try XCTUnwrap(cases.first { $0.trim == Size2(71.9, 150) })
        XCTAssertEqual(DeviceCaseCatalog.pixelSize(of: plateau).width, 920)
        XCTAssertEqual(DeviceCaseCatalog.pixelSize(of: plateau).height, 1843)
    }

    func testCameraZonesSitInsideTheCanvasAndAtTheTopLeft() throws {
        for p in cases {
            XCTAssertEqual(p.restrictedZones.count, 1, p.id)
            let z = try XCTUnwrap(p.restrictedZones.first)
            XCTAssertGreaterThanOrEqual(z.minX, 0, p.id); XCTAssertGreaterThanOrEqual(z.minY, 0, p.id)
            XCTAssertLessThanOrEqual(z.maxX, p.canvas.width, p.id); XCTAssertLessThanOrEqual(z.maxY, p.canvas.height, p.id)
            XCTAssertLessThan(z.height, p.canvas.height / 2, "a camera never takes half the back: \(p.id)")
        }
        let square = try XCTUnwrap(cases.first { $0.name.contains("square") && $0.trim == Size2(77.6, 163) })
        XCTAssertEqual(square.restrictedZones[0], Rect2(x: 8, y: 8, width: 38, height: 38), "5 mm in from the trim, which starts at the bleed")
        let plateau = try XCTUnwrap(cases.first { $0.trim == Size2(78, 163.4) })
        XCTAssertEqual(plateau.restrictedZones[0], Rect2(x: 3, y: 3, width: 78, height: 42), "a plateau spans the full width")
    }

    func testPresetsAreFlaggedAsGenericTemplates() {
        for p in cases {
            XCTAssertTrue(p.note.contains("not a print supplier's template"), p.id)
            XCTAssertTrue(p.note.contains("approximate"), p.id)
            XCTAssertTrue(p.requiresFullBleed)
            XCTAssertFalse(p.transparentBackground)
            XCTAssertTrue(p.exports.contains(.png))
            XCTAssertNil(p.cutLine, "the supplier cuts the case, not us")
            XCTAssertGreaterThan(p.safeRect.width, 0)
        }
    }

    func testDocumentsFindTheirPresetAndRoundTrip() throws {
        for p in cases {
            let doc = p.makeDocument()
            XCTAssertEqual(doc.size, p.canvas)
            let found = try XCTUnwrap(ProductCatalog.preset(for: doc), p.id)
            XCTAssertEqual(found.restrictedZones, p.restrictedZones)
            XCTAssertEqual(try JSONDecoder().decode(ProductPreset.self, from: try JSONEncoder().encode(p)), p)
        }
    }

    func testSameSizeButDifferentCameraAreSeparatePresets() {
        let sameSize = cases.filter { $0.trim == Size2(71.6, 147.6) }
        XCTAssertEqual(sameSize.count, 2)
        XCTAssertNotEqual(sameSize[0].restrictedZones, sameSize[1].restrictedZones)
    }

    func testTabletLabelsSaySo() {
        XCTAssertEqual(cases.filter { $0.name.hasPrefix("Tablet case") }.count, 3)
        XCTAssertEqual(cases.filter { $0.name.hasPrefix("Phone case") }.count, 13)
    }

    func testMugWordingIsUnchanged() {
        XCTAssertEqual(ProductCatalog.mug11.restrictedZoneName, "handle")
        XCTAssertTrue(ProductCatalog.mug11.restrictedZoneAdvice.contains("handle"))
    }
}
