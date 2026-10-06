import SwiftUI

/// Simple wrapping HStack. Not a production layout engine — just enough for a transcript.
struct FlexibleWordWrap<Item: Identifiable, Content: View>: View {
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

struct WordWrapLayout: Layout {
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
