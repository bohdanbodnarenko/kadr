import Shared
import StudioSession
import SwiftUI

/// Click a word to seek, search the recording, cut a sentence (docs/13 T2.3).
@MainActor
struct StudioTranscriptPanel: View {
    let model: StudioDocumentModel
    @State private var selected: TranscriptWord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                TextField("Search", text: Bindable(model).transcriptQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
            }
            if model.chapters.count > 1 {
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groupedTracks, id: \.track) { group in
                        if groupedTracks.count > 1 {
                            Text(label(for: group.track))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                        FlowWords(words: group.words, selected: selected) { word in
                            selected = word
                            model.seekToWord(word)
                        } onCut: { word in
                            model.cutSentence(containing: word)
                        }
                    }
                }
            }
        }
        .padding(10)
    }

    private var groupedTracks: [(track: SpeechTrackKind, words: [TranscriptWord])] {
        let words = model.visibleTranscriptWords
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
}

/// Wrapping word chips. A custom layout rather than a single `Text` so a click lands on
/// a word rather than a character offset we would then have to map back.
private struct FlowWords: View {
    let words: [TranscriptWord]
    let selected: TranscriptWord?
    let onSelect: (TranscriptWord) -> Void
    let onCut: (TranscriptWord) -> Void

    var body: some View {
        FlexibleWordWrap(words: words) { word in
            Text(word.text)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    word == selected ? Color.accentColor.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .onTapGesture { onSelect(word) }
                .contextMenu {
                    Button("Cut this sentence") { onCut(word) }
                }
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
