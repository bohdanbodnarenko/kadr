import Foundation
import HistoryKit

/// Explicit selection state for the history grid (docs/14 UX-21).
///
/// Finder-style: an anchor for shift-range, a focused item for keyboard navigation, and
/// a selected set that can differ when focus moves without changing the selection.
@MainActor
struct HistorySelection {
    var selected: Set<UUID> = []
    var anchor: UUID?
    var focused: UUID?

    var isEmpty: Bool {
        selected.isEmpty
    }

    func contains(_ id: UUID) -> Bool {
        selected.contains(id)
    }

    func isFocused(_ id: UUID) -> Bool {
        focused == id
    }

    mutating func clear() {
        selected.removeAll()
        anchor = nil
        focused = nil
    }

    mutating func selectAll(in records: [HistoryRecord]) {
        let ids = records.map(\.id)
        selected = Set(ids)
        anchor = ids.first
        focused = ids.first
    }

    /// Pointer click with optional command- or shift-modifiers.
    mutating func click(
        _ id: UUID,
        in records: [HistoryRecord],
        command: Bool,
        shift: Bool
    ) {
        let ids = records.map(\.id)
        if shift, let anchor, ids.contains(anchor) {
            selectRange(from: anchor, to: id, in: ids)
        } else if command {
            if selected.contains(id) {
                selected.remove(id)
            } else {
                selected.insert(id)
            }
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
        focused = id
    }

    /// Moves keyboard focus and extends or moves selection like Finder.
    mutating func moveFocus(
        _ direction: FocusDirection,
        in records: [HistoryRecord],
        extending: Bool
    ) {
        let ids = records.map(\.id)
        guard !ids.isEmpty else {
            clear()
            return
        }

        let current = focused.flatMap { ids.firstIndex(of: $0) }
            ?? anchor.flatMap { ids.firstIndex(of: $0) }
            ?? 0
        let columns = HistoryGridMetrics.columns(for: records.count)
        let next = HistoryGridMetrics.index(
            from: current,
            direction: direction,
            columnCount: columns,
            itemCount: ids.count
        )
        let id = ids[next]
        focused = id

        if extending {
            let start = anchor.flatMap { ids.firstIndex(of: $0) } ?? current
            let range = min(start, next) ... max(start, next)
            selected.formUnion(ids[range])
        } else {
            selected = [id]
            anchor = id
        }
    }

    /// After deletion, land focus on the nearest surviving neighbour.
    mutating func focusAfterDeletion(removed: Set<UUID>, in records: [HistoryRecord]) {
        let ids = records.map(\.id)
        guard !ids.isEmpty else {
            clear()
            return
        }
        if let focused, let index = ids.firstIndex(of: focused) {
            selected = [ids[index]]
            anchor = ids[index]
            return
        }
        if let anchor, let index = ids.firstIndex(of: anchor) {
            let neighbour = min(index, ids.count - 1)
            focused = ids[neighbour]
            selected = [ids[neighbour]]
            self.anchor = ids[neighbour]
            return
        }
        let first = ids[0]
        focused = first
        selected = [first]
        anchor = first
    }

    private mutating func selectRange(from: UUID, to: UUID, in ids: [UUID]) {
        guard let start = ids.firstIndex(of: from), let end = ids.firstIndex(of: to) else {
            selected = [to]
            anchor = to
            return
        }
        let range = start <= end ? start ... end : end ... start
        selected.formUnion(ids[range])
    }
}

enum FocusDirection {
    case up, down, left, right
}

/// Grid geometry for arrow-key navigation.
enum HistoryGridMetrics {
    static let minimumCellWidth: CGFloat = 140
    static let maximumCellWidth: CGFloat = 200
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 32

    static func columns(forWindowWidth width: CGFloat = 560) -> Int {
        let available = width - horizontalPadding
        let stride = minimumCellWidth + spacing
        return max(1, Int((available + spacing) / stride))
    }

    static func columns(for itemCount: Int, windowWidth: CGFloat = 560) -> Int {
        min(columns(forWindowWidth: windowWidth), max(itemCount, 1))
    }

    static func index(
        from current: Int,
        direction: FocusDirection,
        columnCount: Int,
        itemCount: Int
    ) -> Int {
        guard itemCount > 0 else { return 0 }
        let row = current / columnCount
        let column = current % columnCount
        let rowCount = (itemCount + columnCount - 1) / columnCount

        switch direction {
        case .left:
            if column > 0 {
                return current - 1
            }
            return current
        case .right:
            if column < columnCount - 1, current + 1 < itemCount {
                return current + 1
            }
            return current
        case .up:
            if row > 0 {
                return max(0, current - columnCount)
            }
            return current
        case .down:
            if row < rowCount - 1 {
                return min(itemCount - 1, current + columnCount)
            }
            return current
        }
    }
}
