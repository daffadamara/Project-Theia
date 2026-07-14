struct GraphDocumentHistory {
    private var undoStack: [GraphDocument] = []
    private var redoStack: [GraphDocument] = []
    private let limit: Int

    init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    mutating func record(_ document: GraphDocument) {
        undoStack.append(document)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll()
    }

    mutating func undo(current: GraphDocument) -> GraphDocument? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(current: GraphDocument) -> GraphDocument? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
