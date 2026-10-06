import AppKit
import ControlKit
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
    /// The word being corrected, and the text typed for it.
    @State private var correcting: TranscriptWord?
    @State private var correctionDraft = ""
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
        .alert(
            Text("Correct Word", bundle: .module),
            isPresented: Binding(get: { correcting != nil }, set: {
                if !$0 {
                    correcting = nil
                }
            }),
            presenting: correcting
        ) { word in
            TextField(String(localized: "Word", bundle: .module), text: $correctionDraft)
            Button(String(localized: "Correct", bundle: .module)) {
                model.correctWord(word, to: correctionDraft)
            }
            .keyboardShortcut(.defaultAction)
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: { word in
            Text("Heard as “\(word.text)”. Captions and exports use the correction.", bundle: .module)
        }
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
            Text("Transcript", bundle: .module)
                .font(.headline)
            Spacer()
            TextField(String(localized: "Find", bundle: .module), text: Bindable(model).transcriptQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
                .onSubmit { stepMatch(by: 1) }
            if !model.transcriptQuery.isEmpty {
                Text(matchLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { stepMatch(by: -1) } label: { Image(systemName: "chevron.up") }
                    .help(Text("Previous match", bundle: .module))
                    .accessibilityLabel(Text("Previous match", bundle: .module))
                    .disabled(matchIDs.isEmpty)
                Button { stepMatch(by: 1) } label: { Image(systemName: "chevron.down") }
                    .help(Text("Next match (Return)", bundle: .module))
                    .accessibilityLabel(Text("Next match", bundle: .module))
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
                                .padding(.top, KadrSpace.small)
                        }
                        // Paragraph-sized rows, so the stack is lazy over a long transcript and
                        // a new active word re-renders the one row it is in (docs/18 STU-15).
                        ForEach(group.chunks) { chunk in
                            FlowWords(
                                words: chunk.words,
                                clips: clips,
                                selectedIDs: chunk.ids.intersection(selectedIDs),
                                activeID: activeWordID.flatMap { chunk.ids.contains($0) ? $0 : nil },
                                marks: TranscriptMarks(
                                    fillers: model.transcriptFillerWords,
                                    matches: chunk.ids.intersection(matchIDs),
                                    currentMatch: currentMatchID.flatMap { chunk.ids.contains($0) ? $0 : nil },
                                    corrections: model.edit.transcriptCorrections
                                ),
                                actions: TranscriptChipActions(
                                    onSelect: handleTap,
                                    onCutSentence: { model.cutSentence(containing: $0) },
                                    onRestore: { model.restoreWords([$0]) },
                                    onCorrect: { word in
                                        correctionDraft = model.edit.transcriptCorrections[word.id] ?? word.text
                                        correcting = word
                                    }
                                )
                            )
                            .equatable()
                        }
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
            Button(String(localized: "Clear", bundle: .module), action: clearSelection)
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
    /// The words in rows of at most `chunkSize`, built once with the group.
    var chunks: [TranscriptChunk] = []

    var id: SpeechTrackKind {
        track
    }

    /// Words per transcript row: about a paragraph.
    static let chunkSize = 80

    init(track: SpeechTrackKind, words: [TranscriptWord]) {
        self.track = track
        self.words = words
        chunks = stride(from: 0, to: words.count, by: Self.chunkSize).map { start in
            TranscriptChunk(words: Array(words[start ..< min(start + Self.chunkSize, words.count)]))
        }
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

/// One row of a transcript track.
struct TranscriptChunk: Identifiable, Equatable {
    let words: [TranscriptWord]
    let ids: Set<String>

    var id: String {
        words.first?.id ?? ""
    }

    init(words: [TranscriptWord]) {
        self.words = words
        ids = Set(words.map(\.id))
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
