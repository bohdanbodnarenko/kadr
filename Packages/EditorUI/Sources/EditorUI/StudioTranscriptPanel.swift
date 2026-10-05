import AppKit
import Shared
import StudioRender
import StudioSession
import SwiftUI

/// Click a word to seek, shift-click a range to cut it, search the recording (docs/13 T2.3).
///
/// Built so that playback does not re-render the transcript (docs/11 S2). The words and
/// their track groups are computed when the transcript or the search changes, not per
/// body; the playhead is watched by `TranscriptPlayheadFollower`, a leaf that only reports
/// when the *word* under it changes; and each chip is `Equatable`, so a new active word
/// re-renders the two chips it concerns rather than all of them.
@MainActor
struct StudioTranscriptPanel: View {
    let model: StudioDocumentModel
    @State private var selectedIDs: Set<String> = []
    @State private var anchor: TranscriptWord?
    /// The words shown, and the same words grouped by track. Cached; see the type comment.
    @State private var displayedWords: [TranscriptWord] = []
    @State private var groupedTracks: [TranscriptTrackGroup] = []
    /// The word under the playhead, as last reported by the follower.
    @State private var activeWordID: String?
    /// The words the search finds, in order, and which one is current (docs/18 STU-10).
    @State private var matchIDs: [String] = []
    @State private var matchIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.chapters.count > 1 {
                chapterRow
            }
            transcriptScroll
            if !selectedWords.isEmpty {
                cutSelectionRow
            }
        }
        .padding(10)
        .onDeleteCommand(perform: cutSelection)
        .onExitCommand { clearSelection() }
        // Arrow keys walk the words, ⇧ extends the selection (docs/14 UX-34).
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: .down) { press in
            moveSelection(by: -1, extending: press.modifiers.contains(.shift))
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            moveSelection(by: 1, extending: press.modifiers.contains(.shift))
        }
        .onAppear(perform: rebuildWords)
        .onChange(of: model.transcript) { rebuildWords() }
        .onChange(of: model.transcriptQuery) { rebuildMatches() }
    }

    private var header: some View {
        HStack {
            Text("Transcript")
                .font(.headline)
            Spacer()
            TextField("Find", text: Bindable(model).transcriptQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
                .onSubmit { stepMatch(by: 1) }
            if !model.transcriptQuery.isEmpty {
                Text(matchLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { stepMatch(by: -1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous match")
                    .accessibilityLabel("Previous match")
                    .disabled(matchIDs.isEmpty)
                Button { stepMatch(by: 1) } label: { Image(systemName: "chevron.down") }
                    .help("Next match (Return)")
                    .accessibilityLabel("Next match")
                    .disabled(matchIDs.isEmpty)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var matchLabel: String {
        guard !matchIDs.isEmpty else { return "No matches" }
        return "\((matchIndex ?? 0) + 1) of \(matchIDs.count)"
    }

    private var currentMatchID: String? {
        matchIndex.flatMap { matchIDs.indices.contains($0) ? matchIDs[$0] : nil }
    }

    private var chapterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.chapters) { chapter in
                    Button(chapter.title) {
                        model.playhead = model.edit.clips.editedTime(forSource: chapter.time) ?? 0
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var transcriptScroll: some View {
        let clips = model.edit.clips
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groupedTracks) { group in
                        if groupedTracks.count > 1 {
                            Text(label(for: group.track))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                        FlowWords(
                            words: group.words,
                            clips: clips,
                            selectedIDs: selectedIDs,
                            activeID: activeWordID,
                            marks: TranscriptMarks(
                                fillers: model.transcriptFillerWords,
                                matches: Set(matchIDs),
                                currentMatch: currentMatchID
                            ),
                            actions: TranscriptChipActions(
                                onSelect: handleTap,
                                onCutSentence: { model.cutSentence(containing: $0) },
                                onRestore: { model.restoreWords([$0]) }
                            )
                        )
                        .equatable()
                    }
                }
            }
            .onChange(of: currentMatchID) {
                guard let currentMatchID else { return }
                proxy.scrollTo(currentMatchID, anchor: .center)
            }
            .background {
                TranscriptPlayheadFollower(
                    clock: model.playheadClock,
                    words: displayedWords,
                    clips: clips
                ) { active in
                    activeWordID = active?.id
                    followPlayhead(to: active, proxy: proxy)
                }
            }
        }
    }

    private var cutSelectionRow: some View {
        HStack(spacing: 6) {
            if selectionIsAllCut {
                Button(selectedWords.count == 1 ? "Restore Word" : "Restore \(selectedWords.count) Words") {
                    model.restoreWords(selectedWords)
                    clearSelection()
                }
            } else {
                Button(cutTitle, action: cutSelection)
                    .foregroundStyle(.red)
            }
            Button("Clear", action: clearSelection)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private var selectedWords: [TranscriptWord] {
        guard !selectedIDs.isEmpty else { return [] }
        return displayedWords.filter { selectedIDs.contains($0.id) }
    }

    /// Whether every selected word's footage is already cut, so the action is Restore.
    private var selectionIsAllCut: Bool {
        !selectedWords.isEmpty && selectedWords.allSatisfy { !model.transcriptWordSurvives($0) }
    }

    private var cutTitle: String {
        selectedWords.count == 1 ? "Cut Word" : "Cut \(selectedWords.count) Words"
    }

    private func rebuildWords() {
        let words = model.transcript?.words ?? []
        displayedWords = words
        groupedTracks = TranscriptTrackGroup.groups(of: words)
        rebuildMatches()
    }

    private func rebuildMatches() {
        matchIDs = StudioDocumentModel.matchingWordIDs(in: model.transcript, query: model.transcriptQuery)
        matchIndex = matchIDs.isEmpty ? nil : 0
    }

    /// Next or previous match, wrapping, and seeks there so the preview shows it.
    private func stepMatch(by step: Int) {
        guard !matchIDs.isEmpty else { return }
        let next = ((matchIndex ?? -step) + step + matchIDs.count) % matchIDs.count
        matchIndex = next
        if let word = displayedWords.first(where: { $0.id == matchIDs[next] }) {
            model.seekToWord(word)
        }
    }

    /// Moves the selection one word, or extends it from the anchor with ⇧.
    private func moveSelection(by step: Int, extending: Bool) -> KeyPress.Result {
        guard !displayedWords.isEmpty else { return .ignored }
        let current = selectedWords.last.flatMap { displayedWords.firstIndex(of: $0) }
            ?? displayedWords.firstIndex { $0.id == activeWordID }
            ?? (step > 0 ? -1 : displayedWords.count)
        let index = min(max(current + step, 0), displayedWords.count - 1)
        let word = displayedWords[index]
        if extending, let ids = rangeIDs(from: anchor, to: word) {
            selectedIDs = ids
        } else {
            selectedIDs = [word.id]
            anchor = word
            model.seekToWord(word)
        }
        return .handled
    }

    private func label(for track: SpeechTrackKind) -> String {
        switch track {
        case .microphone: "You said"
        case .system: "The app said"
        case .mixed: "Spoken"
        }
    }

    private func handleTap(_ word: TranscriptWord) {
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld, let ids = rangeIDs(from: anchor, to: word) {
            selectedIDs = ids
        } else {
            selectedIDs = [word.id]
            anchor = word
            model.seekToWord(word)
        }
    }

    private func rangeIDs(from anchor: TranscriptWord?, to word: TranscriptWord) -> Set<String>? {
        guard let anchor,
              let start = displayedWords.firstIndex(of: anchor),
              let end = displayedWords.firstIndex(of: word)
        else { return nil }
        let range = displayedWords[min(start, end) ... max(start, end)]
        return Set(range.map(\.id))
    }

    private func cutSelection() {
        let words = selectedWords
        guard !words.isEmpty else { return }
        model.cutWords(words)
        clearSelection()
    }

    private func clearSelection() {
        selectedIDs = []
        anchor = nil
    }

    private func followPlayhead(to active: TranscriptWord?, proxy: ScrollViewProxy) {
        guard model.isPlaying, selectedIDs.isEmpty, let active else { return }
        if reduceMotion {
            proxy.scrollTo(active.id, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(active.id, anchor: .center)
            }
        }
    }
}

/// The words of one speech track, in transcript order.
struct TranscriptTrackGroup: Identifiable, Equatable {
    var track: SpeechTrackKind
    var words: [TranscriptWord]

    var id: SpeechTrackKind {
        track
    }

    /// Groups in track order, each keeping the words' own order. One pass over the words.
    static func groups(of words: [TranscriptWord]) -> [TranscriptTrackGroup] {
        var byTrack: [SpeechTrackKind: [TranscriptWord]] = [:]
        for word in words {
            byTrack[word.track, default: []].append(word)
        }
        return byTrack
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { TranscriptTrackGroup(track: $0.key, words: $0.value) }
    }
}

/// Watches the playhead and reports when the word under it changes.
///
/// The only transcript view that reads the playhead, so a playback tick costs one lookup
/// here and nothing else unless the spoken word actually moved on.
private struct TranscriptPlayheadFollower: View {
    let clock: StudioPlayhead
    let words: [TranscriptWord]
    let clips: ClipTimeline
    let onChange: (TranscriptWord?) -> Void

    var body: some View {
        let active = StudioDocumentModel.activeWord(in: words, atEdited: clock.time, clips: clips)
        Color.clear
            .onChange(of: active?.id, initial: true) {
                onChange(active)
            }
    }
}

/// What a chip does when used. A reference-free bundle so chips can compare by value.
private struct TranscriptChipActions {
    let onSelect: (TranscriptWord) -> Void
    let onCutSentence: (TranscriptWord) -> Void
    let onRestore: (TranscriptWord) -> Void
}

/// What marks the words carry besides cut, selected and active.
private struct TranscriptMarks: Equatable {
    var fillers: Set<String>
    var matches: Set<String>
    var currentMatch: String?
}

/// Wrapping word chips. A custom layout rather than a single `Text` so a click lands on
/// a word rather than a character offset we would then have to map back.
///
/// `Equatable` over what it draws, ignoring the actions: SwiftUI cannot compare closures,
/// and without this every parent render re-ran the body for every word.
private struct FlowWords: View, Equatable {
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
private struct TranscriptChip: View, Equatable {
    let word: TranscriptWord
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
            Text(word.text)
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
        .accessibilityLabel(word.text)
        .accessibilityValue(accessibilityState)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Seek to this word. Shift-click to select a range.")
        .contextMenu {
            if isCut {
                Button("Restore Word") { actions.onRestore(word) }
            } else {
                Button("Cut This Sentence") { actions.onCutSentence(word) }
            }
        }
    }

    private var accessibilityState: String {
        var states: [String] = []
        if isCut { states.append("cut") }
        if isFiller, !isCut { states.append("filler") }
        if isActive { states.append("playing") }
        if match != nil { states.append("search match") }
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
