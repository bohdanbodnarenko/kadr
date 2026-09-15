import SwiftUI

extension QuickAccessCardView {
    /// The capture's size on a small glass pill — enough to recognise it, not a status
    /// dashboard. A wide card has room for the name too; the full details are in the tooltip.
    var details: some View {
        Text(detailsText)
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(CardGlass.fill))
            .overlay(Capsule().strokeBorder(CardGlass.edge, lineWidth: 0.5))
            .help(fullDetailsHelp)
            .accessibilityLabel(fullDetailsHelp)
    }

    private var detailsText: String {
        width >= 260 ? "\(item.filename) · \(item.dimensionsText)" : item.dimensionsText
    }

    var fullDetailsHelp: String {
        var parts = [item.filename, item.dimensionsText]
        if let size = item.fileSizeText {
            parts.append(size)
        }
        if item.isStaged {
            parts.append("Staged in the overlay")
        }
        if item.wasCompressed {
            parts.append("Compressed copy on the clipboard")
        }
        return parts.joined(separator: ", ")
    }
}
