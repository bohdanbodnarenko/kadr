import AppKit
import HistoryKit
import SwiftUI

// The card's parts: the picture it shows, and the buttons it draws over it. Split from
// `QuickAccessCardView` because the view was over the 500-line file limit, and these are the
// pieces with no opinion about what a card is.

/// A thumbnail loaded through HistoryKit's downsampling pipeline, so the card never
/// decodes a full-resolution capture (doc 04 §7 rule 2).
///
/// A recording gets a poster frame instead, which ImageIO cannot produce — hence the
/// two paths.
struct ThumbnailImage: View {
    let url: URL
    let maxPixelSize: Int
    let isVideo: Bool

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
            }
        }
        .overlay {
            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white, .black.opacity(0.4))
            }
        }
        .task(id: url) {
            image = isVideo
                ? await VideoPosterFrame.posterFrame(of: url, maxPixelSize: maxPixelSize)
                : ThumbnailLoader().thumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

/// A card action that answers the pointer.
///
/// The action row was `.borderless`, which on macOS draws an icon and nothing else — no
/// hover, no press, no hit area beyond the glyph. On a floating card that is a row of
/// symbols the user cannot tell are buttons until one of them works. This gives each a
/// target, a fill that arrives under the pointer, and a press that reads as a press.
struct CardActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
            .padding(3)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(fill(for: configuration)))
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovering = $0 && isEnabled }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func fill(for configuration: Configuration) -> Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed {
            return 0.22
        }
        return isHovering ? 0.12 : 0
    }
}

/// The close, which has to read over any capture and answer the pointer.
struct CardCloseButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .background {
                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().fill(Color.primary.opacity(isHovering ? 0.14 : 0)))
            }
            .scaleEffect(configuration.isPressed ? 0.9 : (isHovering ? 1.08 : 1))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovering = $0 }
            .contentShape(Circle())
    }
}
