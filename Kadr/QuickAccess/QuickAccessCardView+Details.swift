import SwiftUI

extension QuickAccessCardView {
    /// Filename and size — enough to recognise the capture, not a status dashboard.
    var details: some View {
        Text(isCompact ? item.dimensionsText : "\(item.filename)  \(item.dimensionsText)")
            .lineLimit(1)
            .truncationMode(.middle)
            .font(.caption)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 2)
            .help(fullDetailsHelp)
            .accessibilityLabel(fullDetailsHelp)
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
