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
    var revision = 0
    /// Off for the peek tab's miniatures, where a play glyph would cover the whole picture.
    var showsPlayBadge = true

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
            }
        }
        .overlay {
            if isVideo, showsPlayBadge {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94), .black.opacity(0.32))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
            }
        }
        .task(id: "\(url.path)-\(revision)") {
            let key = CardThumbnailCache.Key(path: url.path, revision: revision, maxPixelSize: maxPixelSize)
            if let cached = CardThumbnailCache.shared.image(for: key) {
                image = cached
                return
            }
            let url = url
            let maxPixelSize = maxPixelSize
            // Off the main thread: a card, its peek miniature and a hover re-render used to
            // decode the same capture up to three times on it (docs/18 OUT-11).
            let decoded = isVideo
                ? await VideoPosterFrame.posterFrame(of: url, maxPixelSize: maxPixelSize)
                : await Task.detached(priority: .userInitiated) {
                    ThumbnailLoader().thumbnail(for: url, maxPixelSize: maxPixelSize)
                }.value
            guard !Task.isCancelled else { return }
            if let decoded {
                CardThumbnailCache.shared.insert(decoded, for: key)
            }
            image = decoded
        }
    }
}

/// The last few card thumbnails, so re-rendering a card does not decode it again.
///
/// Small and bounded: a handful of card-sized bitmaps, gone with the oldest entry. Cleared
/// with the cards, so the idle agent holds none (CLAUDE.md rule 2).
@MainActor
final class CardThumbnailCache {
    struct Key: Hashable {
        let path: String
        let revision: Int
        let maxPixelSize: Int
    }

    static let shared = CardThumbnailCache()
    static let capacity = 12

    private var entries: [Key: CGImage] = [:]
    private var order: [Key] = []

    func image(for key: Key) -> CGImage? {
        entries[key]
    }

    func insert(_ image: CGImage, for key: Key) {
        if entries.updateValue(image, forKey: key) == nil {
            order.append(key)
        }
        while order.count > Self.capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    var count: Int {
        entries.count
    }
}

/// The dark glass the card's controls sit on.
///
/// A fixed translucent fill rather than a system material: the overlay panel is almost
/// never the key window, and a vibrancy material there renders in its flat inactive state —
/// grey on one capture, invisible on the next. This reads the same over any picture.
enum CardGlass {
    static let fill = Color(white: 0.08, opacity: 0.62)
    static let hoverFill = Color(white: 0.08, opacity: 0.8)
    static let edge = Color.white.opacity(0.16)
}

/// A glyph in the card's action bar: white on the bar's glass, a soft disc under the pointer.
struct CardBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBarButtonBody(configuration: configuration)
    }
}

private struct CardBarButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.4))
            .frame(width: QuickAccessCardView.actionButtonSize, height: QuickAccessCardView.actionButtonSize)
            .background(Circle().fill(Color.white.opacity(fill)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovering = $0 && isEnabled }
    }

    private var fill: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed {
            return 0.28
        }
        return isHovering ? 0.16 : 0
    }
}

/// A free-standing round control on the picture: Hide, Trash, and the layout's corners.
struct CardCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 22
    var glyphSize: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        CardCircleButtonBody(configuration: configuration, diameter: diameter, glyphSize: glyphSize)
    }
}

private struct CardCircleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    let glyphSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: glyphSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(isHovering ? CardGlass.hoverFill : CardGlass.fill))
            .overlay(Circle().strokeBorder(CardGlass.edge, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}
