import AppKit
import Shared
import StudioSession
import SwiftUI

/// Click a word to seek, shift-click a range to cut it, search the recording (docs/13 T2.3).
@MainActor
struct StudioTranscriptPanel: View {
    let model: StudioDocumentModel
    @State private var selectedIDs: Set<String> = []
    @State private var anchor: TranscriptWord?

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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groupedTracks, id: \.track) { group in
                        if groupedTracks.count > 1 {
                            Text(label(for: group.track))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                        FlowWords(
                            words: group.words,
                            selectedIDs: selectedIDs,
                            activeID: model.activeTranscriptWord(in: displayedWords)?.id,
                            survives: { model.transcriptWordSurvives($0) },
                            isFiller: { model.isFillerWord($0) },
                            onSelect: handleTap,
                            onCutSentence: { model.cutSentence(containing: $0) }
                        )
                    }
                }
            }
            .onChange(of: model.playhead) { _, _ in
                followPlayhead(proxy: proxy)
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

    private var displayedWords: [TranscriptWord] {
        model.visibleTranscriptWords
    }

    private var selectedWords: [TranscriptWord] {
        displayedWords.filter { selectedIDs.contains($0.id) }
    }

    private var cutTitle: String {
        selectedWords.count == 1 ? "Cut Word" : "Cut \(selectedWords.count) Words"
    }

    private var groupedTracks: [(track: SpeechTrackKind, words: [TranscriptWord])] {
        let words = displayedWords
        let tracks = Array(Set(words.map(\.track))).sorted { $0.rawValue < $1.rawValue }
        return tracks.map { track in (track, words.filter { $0.track == track }) }
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

    private func followPlayhead(proxy: ScrollViewProxy) {
        guard model.isPlaying, selectedIDs.isEmpty,
              let active = model.activeTranscriptWord(in: displayedWords)
        else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(active.id, anchor: .center)
        }
    }
}

/// Wrapping word chips. A custom layout rather than a single `Text` so a click lands on
/// a word rather than a character offset we would then have to map back.
private struct FlowWords: View {
    let words: [TranscriptWord]
    let selectedIDs: Set<String>
    let activeID: String?
    let survives: (TranscriptWord) -> Bool
    let isFiller: (TranscriptWord) -> Bool
    let onSelect: (TranscriptWord) -> Void
    let onCutSentence: (TranscriptWord) -> Void

    var body: some View {
        FlexibleWordWrap(words: words) { word in
            let isCut = !survives(word)
            Text(word.text)
                .underline(isFiller(word) && !isCut, pattern: .dot, color: .orange)
                .strikethrough(isCut, color: .secondary.opacity(0.6))
                .foregroundStyle(isCut ? Color.secondary.opacity(0.45) : Color.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(background(for: word, isCut: isCut), in: RoundedRectangle(cornerRadius: 4))
                .id(word.id)
                .onTapGesture { onSelect(word) }
                .contextMenu {
                    Button("Cut this sentence") { onCutSentence(word) }
                }
        }
    }

    private func background(for word: TranscriptWord, isCut: Bool) -> Color {
        if selectedIDs.contains(word.id) {
            Color.accentColor.opacity(isCut ? 0.12 : 0.24)
        } else if word.id == activeID, !isCut {
            Color.accentColor.opacity(0.2)
        } else if isFiller(word), !isCut {
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
