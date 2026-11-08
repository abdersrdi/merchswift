import Foundation

/// Holds the current document and its undo history. Every change goes through `perform`, which records
/// a snapshot first, so undo and redo restore exactly the earlier state. Snapshots share storage with the
/// live document (Swift copies on write), so a long history stays cheap.
public final class DocumentStore {
    public private(set) var document: Document
    public private(set) var revision = 0

    private struct Entry { var name: String; var document: Document; var coalesceKey: String?; var time: TimeInterval }
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private let maxUndo: Int
    private let clock: () -> TimeInterval
    private let coalesceWindow: TimeInterval

    /// Called after every change, undo and redo.
    public var onChange: (() -> Void)?

    public init(document: Document, maxUndo: Int = 200, coalesceWindow: TimeInterval = 1.0,
                clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.document = document
        self.maxUndo = maxUndo
        self.coalesceWindow = coalesceWindow
        self.clock = clock
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// Applies a change as one undo step. Repeated calls with the same `coalesceKey` within the window
    /// (a drag, a slider) merge into the first one.
    public func perform(_ name: String, coalesceKey: String? = nil, _ change: (inout Document) -> Void) {
        var next = document
        change(&next)
        guard next != document else { return }

        let now = clock()
        if let key = coalesceKey, let last = undoStack.last, last.coalesceKey == key, now - last.time <= coalesceWindow {
            undoStack[undoStack.count - 1].time = now
        } else {
            undoStack.append(Entry(name: name, document: document, coalesceKey: coalesceKey, time: now))
            if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
        }
        redoStack.removeAll()
        document = next
        changed()
    }

    public func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(Entry(name: entry.name, document: document, coalesceKey: nil, time: 0))
        document = entry.document
        changed()
    }

    public func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(Entry(name: entry.name, document: document, coalesceKey: nil, time: 0))
        document = entry.document
        changed()
    }

    private func changed() {
        revision += 1
        onChange?()
    }
}
