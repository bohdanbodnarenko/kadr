import AppKit
import Shared
import StudioRender
import StudioSession
import SwiftUI

/// What a chip does when used. A reference-free bundle so chips can compare by value.
struct TranscriptChipActions {
    let onSelect: (TranscriptWord) -> Void
    let onCutSentence: (TranscriptWord) -> Void
    let onRestore: (TranscriptWord) -> Void
    let onCorrect: (TranscriptWord) -> Void
}

/// What marks the words carry besides cut, selected and active.
struct TranscriptMarks: Equatable {
    var fillers: Set<String>
    var matches: Set<String>
    var currentMatch: String?
    /// The user's corrected text, by word id.
    var corrections: [String: String] = [:]
}

/// Wrapping word chips. A custom layout rather than a single `Text` so a click lands on
/// a word rather than a character offset we would then have to map back.
///
/// `Equatable` over what it draws, ignoring the actions: SwiftUI cannot compare closures,
/// and without this every parent render re-ran the body for every word.
struct FlowWords: View, Equatable {
    let words: [TranscriptWord]
    let clips: ClipTimeline
    let selectedIDs: Set<String>
    let activeID: String?
    let marks: TranscriptMarks
    let actions: TranscriptChipActions

    nonisolated static func == (lhs: FlowWords, rhs: FlowWords) -> Bool {
        lhs.activeID == rhs.activeID
            && lhs.selectedIDs == rhs.selectedIDs
            && lhs.marks == rhs.marks
            && lhs.clips == rhs.clips
            && lhs.words == rhs.words
    }

    var body: some View {
        FlexibleWordWrap(words: words) { word in
            TranscriptChip(
                word: word,
                displayText: marks.corrections[word.id] ?? word.text,
                isCut: !clips.containsSourceTime((word.start + word.end) / 2),
                isFiller: marks.fillers.contains(word.normalized),
                isSelected: selectedIDs.contains(word.id),
                isActive: word.id == activeID,
                match: marks.currentMatch == word.id ? .current : marks.matches.contains(word.id) ? .other : nil,
                actions: actions
            )
            .equatable()
        }
    }
}

/// One word. `Equatable` for the same reason as `FlowWords`.
struct TranscriptChip: View, Equatable {
    let word: TranscriptWord
    /// What the chip says: the correction, or what the engine heard.
    let displayText: String
    let isCut: Bool
    let isFiller: Bool
    let isSelected: Bool
    let isActive: Bool
    let match: Match?
    let actions: TranscriptChipActions

    enum Match: Equatable {
        case current
        case other
    }

    nonisolated static func == (lhs: TranscriptChip, rhs: TranscriptChip) -> Bool {
        lhs.word == rhs.word
            && lhs.displayText == rhs.displayText
            && lhs.isCut == rhs.isCut
            && lhs.isFiller == rhs.isFiller
            && lhs.isSelected == rhs.isSelected
            && lhs.isActive == rhs.isActive
            && lhs.match == rhs.match
    }

    var body: some View {
        Button {
            actions.onSelect(word)
        } label: {
            Text(displayText)
                .underline(isFiller && !isCut, pattern: .dot, color: .orange)
                .strikethrough(isCut, color: .secondary.opacity(0.6))
                .foregroundStyle(isCut ? Color.secondary.opacity(0.45) : Color.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(background, in: RoundedRectangle(cornerRadius: 4))
                // Shape as well as tint (docs/14 UX-34): selected words are outlined and
                // the spoken word carries a bar, so neither depends on telling two
                // accent shades apart.
                .overlay {
                    if isSelected || match == .current {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isSelected ? Color.accentColor : Color.orange, lineWidth: 1.5)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isActive, !isCut {
                        Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .id(word.id)
        .accessibilityLabel(displayText)
        .accessibilityValue(accessibilityState)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text("Seek to this word. Shift-click to select a range.", bundle: .module))
        .contextMenu {
            if isCut {
                Button(String(localized: "Restore Word", bundle: .module)) { actions.onRestore(word) }
            } else {
                Button(String(localized: "Correct Word…", bundle: .module)) { actions.onCorrect(word) }
                Button(String(localized: "Cut This Sentence", bundle: .module)) { actions.onCutSentence(word) }
            }
        }
    }

    private var accessibilityState: String {
        var states: [String] = []
        if isCut {
            states.append("cut")
        }
        if isFiller, !isCut {
            states.append("filler")
        }
        if isActive {
            states.append("playing")
        }
        if match != nil {
            states.append("search match")
        }
        return states.joined(separator: ", ")
    }

    private var background: Color {
        if isSelected {
            Color.accentColor.opacity(isCut ? 0.12 : 0.24)
        } else if isActive, !isCut {
            Color.accentColor.opacity(0.2)
        } else if match != nil {
            Color.yellow.opacity(match == .current ? 0.45 : 0.25)
        } else if isFiller, !isCut {
            Color.orange.opacity(0.16)
        } else {
            Color.clear
        }
    }
}
