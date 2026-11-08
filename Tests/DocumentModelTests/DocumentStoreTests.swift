import XCTest
import CutLine
@testable import DocumentModel

final class DocumentStoreTests: XCTestCase {
    private var now: TimeInterval = 0
    private func makeStore() -> DocumentStore {
        let layer = Layer(name: "a", content: .shape(ShapeContent(path: .rect(Rect2(x: 0, y: 0, width: 10, height: 10)), fill: .black)))
        return DocumentStore(document: Document(size: Size2(100, 100), layers: [layer]), clock: { self.now })
    }

    func testUndoRedoRestoresExactState() {
        let store = makeStore()
        let original = store.document
        store.perform("Rename") { $0.layers[0].name = "b" }
        store.perform("Hide") { $0.layers[0].isVisible = false }
        XCTAssertEqual(store.undoName, "Hide")
        store.undo()
        XCTAssertEqual(store.document.layers[0].name, "b")
        XCTAssertTrue(store.document.layers[0].isVisible)
        store.undo()
        XCTAssertEqual(store.document, original)
        XCTAssertFalse(store.canUndo)
        store.redo()
        store.redo()
        XCTAssertEqual(store.document.layers[0].name, "b")
        XCTAssertFalse(store.document.layers[0].isVisible)
        XCTAssertFalse(store.canRedo)
    }

    func testNewChangeClearsRedo() {
        let store = makeStore()
        store.perform("One") { $0.title = "1" }
        store.undo()
        XCTAssertTrue(store.canRedo)
        store.perform("Two") { $0.title = "2" }
        XCTAssertFalse(store.canRedo)
    }

    func testNoOpChangeIsNotRecorded() {
        let store = makeStore()
        store.perform("Nothing") { _ in }
        XCTAssertFalse(store.canUndo)
        XCTAssertEqual(store.revision, 0)
    }

    func testDragIsOneUndoStep() {
        let store = makeStore()
        let id = store.document.layers[0].id
        for i in 1...30 {
            now += 0.016
            store.perform("Move", coalesceKey: "drag-\(id)") { $0.layers[0].transform = .translation(Double(i), 0) }
        }
        XCTAssertEqual(store.document.layers[0].transform.tx, 30)
        store.undo()
        XCTAssertEqual(store.document.layers[0].transform.tx, 0, "the whole drag undoes in one step")
        XCTAssertFalse(store.canUndo)
    }

    func testCoalescingStopsAfterThePause() {
        let store = makeStore()
        store.perform("Move", coalesceKey: "k") { $0.layers[0].transform = .translation(1, 0) }
        now += 5
        store.perform("Move", coalesceKey: "k") { $0.layers[0].transform = .translation(2, 0) }
        store.undo()
        XCTAssertEqual(store.document.layers[0].transform.tx, 1)
    }

    func testHistoryIsCapped() {
        let layer = Layer(name: "a", content: .group([]))
        let store = DocumentStore(document: Document(size: Size2(10, 10), layers: [layer]), maxUndo: 5, clock: { self.now })
        for i in 0..<20 { store.perform("n\(i)") { $0.title = "t\(i)" } }
        var steps = 0
        while store.canUndo { store.undo(); steps += 1 }
        XCTAssertEqual(steps, 5)
    }

    func testOnChangeFires() {
        let store = makeStore()
        var calls = 0
        store.onChange = { calls += 1 }
        store.perform("x") { $0.title = "x" }
        store.undo()
        store.redo()
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(store.revision, 3)
    }
}
