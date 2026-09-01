import AppKit
import HistoryKit
import SettingsKit
import Shared
import SwiftUI

/// What a card can do (docs/03 §2). Stubs are wired to the milestones that fill them in.
struct QuickAccessCardActions {
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var annotate: () -> Void = {}
    var pin: () -> Void = {}
    var recognizeText: () -> Void = {}
    var delete: () -> Void = {}
    var dismiss: () -> Void = {}
    /// Resolves the file to hand to a receiver, finalising a staged capture on the way.
    /// Called when the drop asks for the bytes, never when the drag starts (docs/07 C1).
    var resolveForDrag: @MainActor @Sendable () -> URL? = { nil }
    /// The drag ended; `true` when a receiver took the file.
    var dragCompleted: @MainActor @Sendable (Bool) -> Void = { _ in }
    /// Turns a recording into a GIF (docs/03 §1.8). Only offered on a recording.
    var exportGIF: () -> Void = {}
    /// Re-encodes the capture smaller and copies it (docs/09 U2.4).
    var compress: () -> Void = {}
    /// Opens a recording in the trim window (docs/03 §1.8). Only offered on a recording.
    var trim: () -> Void = {}
    var trimAvailable = false
    /// Opens a recording in the studio (docs/09 U3). Offered only when the recording still
    /// has a session beside it — without one there is nothing to edit but the trim.
    var studio: () -> Void = {}
    var studioAvailable = false
    /// Hover pauses auto-dismiss; it does not claim the card (docs/03 §2).
    var setHovered: (Bool) -> Void = { _ in }
    /// Dragging pauses auto-dismiss until the drop finishes.
    var beginDrag: () -> Void = {}
    /// Tucks the stack into the peek tab (swipe toward the screen edge).
    var peek: () -> Void = {}
    /// Whether Annotate, Pin and OCR do anything yet.
    var annotateAvailable = false
    var pinAvailable = false
    var textAvailable = false
}

/// The card's content (docs/03 §2): thumbnail, hover details, expanding action row.
struct QuickAccessCardView: View {
    let item: QuickAccessItem
    let actions: QuickAccessCardActions
    let width: CGFloat
    /// Which buttons this card offers, and where (docs/09 U2.3).
    var layout: CardLayout = .standard

    @State private var isHovering = false
    /// Pinned open by a click, so the actions stay while the pointer travels to one.
    @State private var isExpanded = false

    /// Hovering reveals the actions; a click pins them.
    private var showsActions: Bool {
        isHovering || isExpanded
    }

    /// The scale of the screen this card is on.
    ///
    /// Read rather than assumed: hard-coding 2× decoded twice the pixels needed on a
    /// non-Retina display, and — once Apple ships anything above 2× — too few on a better
    /// one (docs/07 LOW).
    @Environment(\.displayScale) private var displayScale

    // Smaller than it was (140/36/8). A card is a notification about something that
    // already happened, and this one occupied a fifth of the height of a laptop screen for
    // a thumbnail nobody inspects at that size — what it needs to do is be recognisable and
    // reachable, which 104 points manages.
    private static let thumbnailHeight: CGFloat = 104
    private static let actionRowHeight: CGFloat = 30
    private static let padding: CGFloat = 7

    /// The panel needs its height before SwiftUI has laid anything out.
    static func height(forWidth width: CGFloat, item: QuickAccessItem) -> CGFloat {
        thumbnailHeight + actionRowHeight + padding * 2
    }

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
            // Actions on hover, details otherwise (docs/08 §2 item 13).
            //
            // They used to be behind a click on the thumbnail, which is the wrong gesture
            // twice over: the card is a thing you want to *drag*, so clicking it to reveal a
            // menu fights the drag, and a user who does not know the click exists sees a
            // picture with no actions at all. Hovering a card to see what it can do is what
            // every other capture tool does and what people try first.
            if showsActions {
                actionRow
                    .transition(.opacity)
            } else {
                details
                    .transition(.opacity)
            }
        }
        .padding(Self.padding)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.24 : 0.12))
        )
        // Lifts a little under the pointer, so the card the pointer is on is obvious in a
        // stack of them.
        .shadow(color: .black.opacity(isHovering ? 0.28 : 0.16), radius: isHovering ? 16 : 8, y: isHovering ? 5 : 2)
        .scaleEffect(isHovering ? 1.015 : 1, anchor: .center)
        .animation(.snappy(duration: 0.16), value: isHovering)
        .animation(.snappy(duration: 0.16), value: isExpanded)
        .onHover { hovering in
            isHovering = hovering
            actions.setHovered(hovering)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture \(item.filename), \(item.dimensionsText)")
    }

    private var thumbnail: some View {
        ThumbnailImage(
            url: item.fileURL,
            maxPixelSize: Int((width * displayScale).rounded()),
            isVideo: item.isVideo
        )
        .frame(height: Self.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        // One AppKit view owns click, double-click and drag. A file promise rather
        // than a URL, so a staged capture is finalised when the receiver asks for it
        // and an abandoned drag changes nothing (docs/03 §2, §6; docs/09 U0.1).
        .overlay(
            FilePromiseDragView(
                payload: {
                    FilePromisePayload(
                        suggestedName: item.filename,
                        contentType: item.contentType,
                        resolve: actions.resolveForDrag,
                        completed: actions.dragCompleted
                    )
                },
                dragImage: { NSImage(contentsOf: item.fileURL) },
                // Pins the actions open. Hover already showed them, so this is for keeping
                // them while the pointer leaves the card — not for discovering they exist.
                onTap: { isExpanded.toggle() },
                onDoubleTap: {
                    if actions.annotateAvailable {
                        actions.annotate()
                    }
                },
                onDragBegan: { actions.beginDrag() }
            )
        )
        .overlay {
            if isHovering {
                hoverOverlay
            }
        }
        // Always in the same place, hover or not.
        //
        // There used to be one in the details row and another over the thumbnail, so the
        // close did not disappear on hover — it *moved*, from the bottom of the card to the
        // top corner, out from under a pointer already travelling towards it. A target that
        // relocates as you reach for it is worse than one that is simply absent.
        .overlay(alignment: .topTrailing) {
            hideButton
                .padding(6)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Hover to see the actions, double-tap to open, or drag to another app")
    }

    private var details: some View {
        HStack(spacing: 6) {
            Text(isHovering ? item.filename : item.dimensionsText)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if isHovering, let size = item.fileSizeText {
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if item.wasCompressed {
                compressionBadge
            }
            if item.isStaged {
                Image(systemName: "tray")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Kept in the overlay only. Saved when you act on it.")
            }
        }
        .frame(height: Self.actionRowHeight)
    }

    /// What the last compression achieved (docs/09 U2.4).
    ///
    /// Shown even when it achieved nothing: a flat screenshot re-encodes larger than its
    /// PNG, and a badge that only ever appears on success would leave the user pressing
    /// the button again wondering whether it worked.
    @ViewBuilder
    private var compressionBadge: some View {
        if let savings = item.compressionSavings, savings > 0 {
            Text("−\(Int((savings * 100).rounded()))%")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.22), in: Capsule())
                .help("The compressed copy is on the clipboard.")
        } else {
            Text("no smaller")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("This capture is already about as small as it gets.")
        }
    }

    /// Hover chrome: the layout's corner actions, plus a close that hides without deleting.
    ///
    /// Corners were configured in settings and never drawn — they only exist on hover,
    /// over the thumbnail, which is where there is room for them (docs/09 U2.3).
    private var hoverOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.32))
                .allowsHitTesting(false)
            VStack {
                HStack(alignment: .top) {
                    corner(.topLeading)
                    Spacer()
                    corner(.topTrailing)
                }
                Spacer()
                HStack {
                    corner(.bottomLeading)
                    Spacer()
                    corner(.bottomTrailing)
                }
            }
            .padding(6)
        }
    }

    /// Hide, not delete. The file stays where the save policy put it (docs/03 §2).
    ///
    /// Sits over the thumbnail's top corner whether or not the card is hovered, so it is
    /// always in the same place — and carries its own material, because it has to stay
    /// legible over whatever the capture happens to be.
    private var hideButton: some View {
        Button(action: actions.dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(CardCloseButtonStyle())
        .help("Hide — the file stays")
        .accessibilityLabel("Hide card")
    }

    /// The buttons the user's layout asks for, in the order they asked for them
    /// (docs/09 U2.3).
    ///
    /// The layout is read rather than hard-coded, and filtered by what the capture is:
    /// one layout serves both kinds, so placing Trim shows it on recordings and hides it
    /// on screenshots without anybody keeping two layouts in step.
    private var actionRow: some View {
        HStack(spacing: 2) {
            ForEach(layout.actions(in: .column, for: item.captureKind), id: \.self) { action in
                button(for: action)
            }
        }
        .frame(height: Self.actionRowHeight)
    }

    /// The corner buttons, shown on hover over the thumbnail.
    private func corner(_ slot: CardSlot) -> some View {
        ForEach(layout.actions(in: slot, for: item.captureKind), id: \.self) { action in
            button(for: action)
                .background(.regularMaterial, in: Circle())
        }
    }

    @ViewBuilder
    private func button(for cardAction: CardAction) -> some View {
        switch cardAction {
        case .share:
            // ShareLink is its own control: it needs the item, not a closure, so the
            // system picker can offer the right services for the file.
            ShareLink(item: item.fileURL) {
                Image(systemName: cardAction.systemImage)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("Share")
        default:
            action(
                cardAction.title,
                systemImage: cardAction.systemImage,
                enabled: isEnabled(cardAction),
                action: handler(for: cardAction)
            )
        }
    }

    private func isEnabled(_ cardAction: CardAction) -> Bool {
        switch cardAction {
        case .annotate: actions.annotateAvailable
        case .pin: actions.pinAvailable
        case .recognizeText: actions.textAvailable
        case .trim: actions.trimAvailable
        case .studio: actions.studioAvailable
        default: true
        }
    }

    /// What each button does.
    ///
    /// A table rather than a switch: it is a lookup with one arm per action and no
    /// branching worth the name, and as a switch it reads to a complexity check as a
    /// function that decides eleven things.
    ///
    /// Share is absent on purpose — it is drawn by its own case above, because
    /// `NSSharingServicePicker` needs the button's frame to point at.
    private var handlers: [CardAction: () -> Void] {
        [
            .copy: actions.copy,
            .save: actions.save,
            .annotate: actions.annotate,
            .pin: actions.pin,
            .recognizeText: actions.recognizeText,
            .trim: actions.trim,
            .studio: actions.studio,
            .exportGIF: actions.exportGIF,
            .compress: actions.compress,
            .delete: actions.delete
        ]
    }

    private func handler(for cardAction: CardAction) -> () -> Void {
        handlers[cardAction] ?? {}
    }

    private func action(
        _ title: String,
        systemImage: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(CardActionButtonStyle())
        .disabled(!enabled)
        .help(enabled ? title : "\(title) — coming soon")
        .accessibilityLabel(title)
    }
}

/// A thumbnail loaded through HistoryKit's downsampling pipeline, so the card never
/// decodes a full-resolution capture (doc 04 §7 rule 2).
///
/// A recording gets a poster frame instead, which ImageIO cannot produce — hence the
/// two paths.
private struct ThumbnailImage: View {
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
private struct CardActionButtonStyle: ButtonStyle {
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
private struct CardCloseButtonStyle: ButtonStyle {
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
