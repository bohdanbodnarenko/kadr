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
        .onAppear(perform: rebuildWords)
        .onChange(of: model.transcript) { rebuildWords() }
        .onChange(of: model.transcriptQuery) { rebuildWords() }
    }

    private var header: some View {
        HStack {
            Text("Transcript")
                .font(.headline)
            Spacer()
            TextField("Search", text: Bindable(model).transcriptQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
        }
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
                            actions: TranscriptChipActions(
                                onSelect: handleTap,
                                onCutSentence: { model.cutSentence(containing: $0) }
                            )
                        )
                        .equatable()
                    }
                }
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
            Button(cutTitle, action: cutSelection)
                .foregroundStyle(.red)
            Button("Clear", action: clearSelection)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private var selectedWords: [TranscriptWord] {
        guard !selectedIDs.isEmpty else { return [] }
        return displayedWords.filter { selectedIDs.contains($0.id) }
    }

    private var cutTitle: String {
        selectedWords.count == 1 ? "Cut Word" : "Cut \(selectedWords.count) Words"
    }

    private func rebuildWords() {
        let words = StudioDocumentModel.visibleWords(in: model.transcript, query: model.transcriptQuery)
        displayedWords = words
        groupedTracks = TranscriptTrackGroup.groups(of: words)
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
    let actions: TranscriptChipActions

    nonisolated static func == (lhs: FlowWords, rhs: FlowWords) -> Bool {
        lhs.activeID == rhs.activeID
            && lhs.selectedIDs == rhs.selectedIDs
            && lhs.clips == rhs.clips
            && lhs.words == rhs.words
    }

    var body: some View {
        FlexibleWordWrap(words: words) { word in
            TranscriptChip(
                word: word,
                isCut: !clips.containsSourceTime((word.start + word.end) / 2),
                isFiller: TranscriptCutPlanner.fillerWords.contains(word.normalized),
                isSelected: selectedIDs.contains(word.id),
                isActive: word.id == activeID,
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
    let actions: TranscriptChipActions

    nonisolated static func == (lhs: TranscriptChip, rhs: TranscriptChip) -> Bool {
        lhs.word == rhs.word
            && lhs.isCut == rhs.isCut
            && lhs.isFiller == rhs.isFiller
            && lhs.isSelected == rhs.isSelected
            && lhs.isActive == rhs.isActive
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
        }
        .buttonStyle(.plain)
        .id(word.id)
        .accessibilityLabel(word.text)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Seek to this word. Shift-click to select a range.")
        .contextMenu {
            Button("Cut this sentence") { actions.onCutSentence(word) }
        }
    }

    private var background: Color {
        if isSelected {
            Color.accentColor.opacity(isCut ? 0.12 : 0.24)
        } else if isActive, !isCut {
            Color.accentColor.opacity(0.2)
        } else if isFiller, !isCut {
            Color.orange.opacity(0.16)
        } else {
            Color.clear
        }
    }
}

/// Simple wrapping HStack. Not a production layout engine — just enough for a transcript.
private struct FlexibleWordWrap<Item: Identifiable, Content: View>: View {
    let words: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        // A wrapping layout without UIKit: `ViewThatFits` per row would be another
        // implementation; this uses a flow via `Layout`. Keep it cheap — transcripts
        // are thousands of words, not tens of thousands.
        WordWrapLayout {
            ForEach(words) { word in
                content(word)
            }
        }
    }
}

private struct WordWrapLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + 2
                row = 0
            }
            row = max(row, size.height)
            x += size.width
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + 2
                row = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            row = max(row, size.height)
        }
    }
}
