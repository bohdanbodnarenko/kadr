import SwiftUI

extension QuickAccessCardView {
    /// Filename, dimensions and size — the things docs/03 §2 asks hover to show.
    var details: some View {
        Group {
            if isCompact {
                HStack(spacing: 6) {
                    Text(item.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let status = compactStatusText {
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Text(item.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(item.dimensionsText)
                        .foregroundStyle(.secondary)
                    if let size = item.fileSizeText {
                        Text(size)
                            .foregroundStyle(.secondary)
                    }
                    if item.wasCompressed {
                        compressionBadge
                    }
                    if item.isStaged {
                        Image(systemName: "tray")
                            .help("Kept in the overlay only. Saved when you act on it.")
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .help(fullDetailsHelp)
        .accessibilityLabel(fullDetailsHelp)
    }

    /// One priority status at compact widths (docs/14 UX-19).
    var compactStatusText: String? {
        if item.isStaged {
            return "Staged"
        }
        if item.wasCompressed {
            if let savings = item.compressionSavings, savings > 0 {
                return "−\(Int((savings * 100).rounded()))%"
            }
            return "No smaller"
        }
        return item.dimensionsText
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

    /// What the last compression achieved (docs/09 U2.4).
    ///
    /// Shown even when it achieved nothing: a flat screenshot re-encodes larger than its
    /// PNG, and a badge that only ever appears on success would leave the user pressing
    /// the button again wondering whether it worked.
    @ViewBuilder
    var compressionBadge: some View {
        if let savings = item.compressionSavings, savings > 0 {
            Text("−\(Int((savings * 100).rounded()))%")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.35), in: Capsule())
                .help("The compressed copy is on the clipboard.")
        } else {
            Text("no smaller")
                .help("This capture is already about as small as it gets.")
        }
    }
}
