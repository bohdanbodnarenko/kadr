import AppKit
import HistoryKit
import SwiftUI

/// History acting like a Finder window (docs/18 OUT-8): commands apply to the selection,
/// typing jumps to a name, and a double-click opens the capture rather than a card.
extension HistoryView {
    /// What a context-menu command on `record` acts on: the whole selection when the
    /// record is part of it, as in Finder; otherwise just that record.
    func targets(for record: HistoryRecord) -> [UUID] {
        selection.selected.contains(record.id) && selection.selected.count > 1
            ? Array(selection.selected)
            : [record.id]
    }

    /// Double-click and Return: a recording opens in the studio (or its card), and an
    /// image opens in the editor. A card parked in the screen corner was a strange place for
    /// a double-click to land.
    func openDefault(_ record: HistoryRecord) {
        if record.kind == .video || record.kind.opensInEditor {
            open(record)
        } else if let onAnnotate = controller.onAnnotate {
            onAnnotate(record)
        } else {
            open(record)
        }
    }

    /// Selects the first capture whose name starts with what the user typed.
    ///
    /// Keys within `typeSelectInterval` of each other build one prefix, as in Finder; no
    /// timer, the next key compares timestamps.
    func typeSelect(_ characters: String, at now: Date = Date()) -> Bool {
        guard let character = characters.first, characters.count == 1,
              character.isLetter || character.isNumber
        else { return false }
        let continues = now.timeIntervalSince(typeSelectTypedAt) < Self.typeSelectInterval
        let prefix = (continues ? typeSelectPrefix : "") + String(character)
        typeSelectPrefix = prefix
        typeSelectTypedAt = now
        guard let match = HistorySelection.firstMatch(
            prefix: prefix,
            in: controller.records.map { ($0.id, title(for: $0)) }
        ) else { return true }
        selection.selected = [match]
        selection.anchor = match
        selection.focused = match
        return true
    }

    static var typeSelectInterval: TimeInterval {
        1
    }
}

extension HistorySelection {
    /// The first id whose title starts with `prefix`, ignoring case and diacritics.
    nonisolated static func firstMatch(prefix: String, in titles: [(UUID, String)]) -> UUID? {
        titles.first { _, title in
            title.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }?.0
    }
}
