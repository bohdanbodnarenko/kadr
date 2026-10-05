import Foundation

public extension AnnotationDocument {
    // MARK: - Undo and redo

    var canUndo: Bool {
        historyIndex > 0
    }

    var canRedo: Bool {
        historyIndex < history.count - 1
    }

    @discardableResult
    mutating func undo() -> Bool {
        // An open gesture (a live text field, a drag) is closed first, so undo steps back
        // over the whole of it rather than leaving half of it behind (docs/18 ED-5).
        if gestureBaseline != nil {
            endGesture()
        }
        guard canUndo else { return false }
        historyIndex -= 1
        pruneSelection()
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        if gestureBaseline != nil {
            endGesture()
        }
        guard canRedo else { return false }
        historyIndex += 1
        pruneSelection()
        return true
    }

    /// Folds the newest undo step into the one before it, so two edits undo as one — placing
    /// a text box and typing into it (docs/18 ED-5). A fold that leaves a step changing
    /// nothing drops that step too. Only at the top of history and with no gesture open.
    @discardableResult
    mutating func foldLastStep() -> Bool {
        guard gestureBaseline == nil, historyIndex >= 2, historyIndex == history.count - 1 else { return false }
        history.remove(at: historyIndex - 1)
        orientationHistory.remove(at: historyIndex - 1)
        historyIndex -= 1
        if history[historyIndex] == history[historyIndex - 1],
           orientationHistory[historyIndex] == orientationHistory[historyIndex - 1] {
            history.removeLast()
            orientationHistory.removeLast()
            historyIndex -= 1
        }
        return true
    }
}
