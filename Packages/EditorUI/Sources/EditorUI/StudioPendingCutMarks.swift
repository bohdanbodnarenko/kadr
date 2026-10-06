import SwiftUI

/// The cuts Tidy proposes, drawn over the clips before anything is applied
/// (docs/17 T-STU-6), so the user sees what would go and where.
///
/// Selected cuts are hatched red, deselected ones only outlined with a dashed line. The
/// hatching and the dash carry the difference as well as the colour does, so it survives
/// Differentiate Without Colour and red–green colour blindness (docs/18 X-3). Tidy runs on
/// an uncut recording, so source time is edited time; the mapping is still used so a mark
/// can never land off the clips.
struct PendingCutMarks: View {
    let model: StudioDocumentModel
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.pendingCuts) { cut in
                if let start = model.edit.clips.editedTime(forSource: cut.start) {
                    let end = model.edit.clips.editedTime(forSource: cut.end) ?? start + cut.duration
                    let selected = model.selectedCutIDs.contains(cut.id)
                    mark(selected: selected)
                        .frame(width: max((end - start) * scale, 2))
                        .offset(x: start * scale)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func mark(selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        return shape
            .fill(Color.red.opacity(selected ? 0.22 : 0))
            .overlay {
                if selected {
                    CutHatching()
                        .stroke(Color.red.opacity(0.7), lineWidth: 1)
                        .clipShape(shape)
                }
            }
            .overlay(
                shape.strokeBorder(
                    Color.red.opacity(selected ? 0.9 : 0.6),
                    style: StrokeStyle(lineWidth: 1, dash: selected ? [] : [3, 2])
                )
            )
    }
}

/// Diagonal lines across a rect, 6 pt apart.
struct CutHatching: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
