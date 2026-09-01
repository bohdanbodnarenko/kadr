import AppKit
import SettingsKit
import SwiftUI

/// Copy for the collapsed overlay tab (docs/03 §2).
enum OverlayPeekCopy {
    static func title(count: Int, hasVideo: Bool) -> String {
        let noun = hasVideo ? "Capture" : "Screenshot"
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

/// A pill the same width as the cards, docked to the configured corner.
struct QuickAccessPeekTabView: View {
    static let pillHeight: CGFloat = 42

    let title: String
    let corner: OverlayCorner
    let onExpand: () -> Void
    let onDismissAll: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onExpand) {
                HStack(spacing: 7) {
                    Image(systemName: corner.isBottom ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show recent captures")

            Divider()
                .frame(height: 14)

            peekDismissButton
                .padding(.trailing, 6)
        }
        // Its own height, not its container's.
        //
        // The button inside asks for `maxHeight: .infinity` so its click target fills the
        // pill. That used to be bounded by the pill's own 42-point panel; in the shared
        // full-screen overlay panel nothing bounds it, so the pill grew into a full-height
        // slab down the side of the screen — one that took clicks, too, because the overlay
        // publishes it as interactive.
        .frame(height: Self.pillHeight)
        .background(.regularMaterial, in: shape)
        .overlay {
            shape
                .strokeBorder(Color.primary.opacity(0.12))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). Show recent captures")
    }

    private var peekDismissButton: some View {
        Button(action: onDismissAll) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hide all — files stay")
        .accessibilityLabel("Hide all cards")
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: corner.isBottom ? 14 : 0,
            bottomLeadingRadius: corner.isBottom ? 0 : 14,
            bottomTrailingRadius: corner.isBottom ? 0 : 14,
            topTrailingRadius: corner.isBottom ? 14 : 0,
            style: .continuous
        )
    }
}
