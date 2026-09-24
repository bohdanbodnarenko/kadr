import SwiftUI

/// The cuts Tidy proposes, drawn over the clips before anything is applied
/// (docs/17 T-STU-6), so the user sees what would go and where.
///
/// Selected cuts are hatched red, deselected ones only outlined. Tidy runs on an uncut
/// recording, so source time is edited time; the mapping is still used so a mark can
/// never land off the clips.
struct PendingCutMarks: View {
    let model: StudioDocumentModel
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.pendingCuts) { cut in
                if let start = model.edit.clips.editedTime(forSource: cut.start) {
                    let end = model.edit.clips.editedTime(forSource: cut.end) ?? start + cut.duration
                    let selected = model.selectedCutIDs.contains(cut.id)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red.opacity(selected ? 0.35 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.red.opacity(selected ? 0.9 : 0.5), lineWidth: 1)
                        )
                        .frame(width: max((end - start) * scale, 2))
                        .offset(x: start * scale)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
