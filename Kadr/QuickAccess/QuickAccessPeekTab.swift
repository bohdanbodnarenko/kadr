import AppKit
import ControlKit
import SettingsKit
import SwiftUI

/// Copy for the collapsed overlay tab (docs/03 §2).
enum OverlayPeekCopy {
    static func title(count: Int, hasVideo: Bool) -> String {
        hasVideo
            ? KadrText.counted("^[\(count) Capture](inflect: true)")
            : KadrText.counted("^[\(count) Screenshot](inflect: true)")
    }
}

/// The stack, tucked away while the editor is open: a glass pill the width of the cards,
/// in the same corner (docs/03 §2).
///
/// It shows the captures themselves — the newest few, fanned like a stack — rather than a
/// count beside a chevron, so what is waiting here is recognisable at a glance. Fully rounded:
/// it floats inset from the screen edge, and square corners on one side read as a tab stuck
/// to an edge it is not touching.
struct QuickAccessPeekTabView: View {
    static let pillHeight: CGFloat = 50
    private static let thumbnailSize = CGSize(width: 34, height: 26)
    private static let maxThumbnails = 3

    let title: String
    let corner: OverlayCorner
    /// Newest first.
    let items: [QuickAccessItem]
    let onExpand: () -> Void
    let onDismissAll: () -> Void

    @State private var isHovering = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onExpand) {
                HStack(spacing: 9) {
                    thumbnails
                    VStack(alignment: .leading, spacing: 1) {
                        // Scales a touch before it truncates: "3 Screenshots" has to fit the
                        // narrowest card width, and a clipped count is the one thing it says.
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        HStack(spacing: 3) {
                            Text("Show")
                            Image(systemName: corner.isBottom ? "chevron.up" : "chevron.down")
                                .font(KadrType.font(KadrType.micro, weight: .bold))
                        }
                        .font(.system(size: KadrType.caption))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show recent captures")

            PeekDismissButton(action: onDismissAll)
                .padding(.trailing, KadrSpace.medium)
        }
        // Its own height, not its container's: the button's click target asks for all the
        // height it can get, and in the full-screen overlay panel nothing else bounds it.
        .frame(height: Self.pillHeight)
        .background(shape.fill(.regularMaterial))
        .overlay {
            shape
                .fill(Color.primary.opacity(isHovering ? 0.05 : 0))
                .allowsHitTesting(false)
        }
        .overlay {
            shape
                .strokeBorder(KadrFill.stroke, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .compositingGroup()
        .kadrShadow(.floating)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). Show recent captures")
    }

    /// The newest captures, fanned: the newest upright on top, older ones tilting out
    /// behind it.
    private var thumbnails: some View {
        let shown = Array(items.prefix(Self.maxThumbnails).enumerated())
        return ZStack {
            ForEach(shown.reversed(), id: \.element.id) { index, item in
                ThumbnailImage(
                    url: item.fileURL,
                    maxPixelSize: Int((Self.thumbnailSize.width * displayScale).rounded()),
                    isVideo: item.isVideo,
                    revision: item.contentRevision,
                    showsPlayBadge: false
                )
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: KadrRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: KadrRadius.medium, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
                )
                .kadrShadow(.glyph)
                .rotationEffect(.degrees(Double(index) * -7), anchor: .bottom)
                .offset(x: CGFloat(index) * -3)
            }
        }
        .frame(width: Self.thumbnailSize.width + 6, height: Self.thumbnailSize.height + 6)
        .accessibilityHidden(true)
    }
}

/// Hide-all, with a generous round target that shows itself under the pointer.
private struct PeekDismissButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: KadrType.micro, weight: .bold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Hide all — files stay")
        .accessibilityLabel("Hide all cards")
    }
}
