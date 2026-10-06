import AppKit
import ControlKit
import HistoryKit
import SettingsKit
import Shared
import SwiftUI

/// The card (docs/03 §2): a thumbnail at rest, a short action row on hover.
///
/// At rest it is only the capture. Hover keeps that picture visible — a gradient at the
/// edges, not a frosted sheet — and offers the daily actions in one row. Hide sits in the
/// corner; everything else is More, the context menu, or a shortcut.
struct QuickAccessCardView: View {
    let item: QuickAccessItem
    let actions: QuickAccessCardActions
    let width: CGFloat
    /// Which buttons this card offers, and where (docs/09 U2.3).
    var layout: CardLayout = .standard
    /// Held back while the stack is reflowing, so the actions do not flash across every
    /// card that passes under a stationary pointer.
    var suppressHoverChrome = false
    /// A dot on the newest card when several are stacked (CleanShot §6.3).
    var showsNewestIndicator = false
    /// Trash control for captures already on disk (CleanShot §6.2).
    var showsTrashButton = false
    /// Actions stay visible instead of appearing on hover.
    var alwaysShowActions = false
    /// Focus Quick Access picked this card (docs/18 UX-18).
    var requestsKeyboardFocus = false

    @State private var isHovering = false
    /// Sticky single-click expansion (docs/03 §2, docs/14 UX-18).
    @State private var isExpanded = false
    @FocusState private var isFocused: Bool

    /// The scale of the screen this card is on.
    ///
    /// Read rather than assumed: hard-coding 2× decoded twice the pixels needed on a
    /// non-Retina display, and — once Apple ships anything above 2× — too few on a better
    /// one (docs/07 LOW).
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cornerRadius: CGFloat = 14
    /// What is left of an older card once the stack runs out of room.
    static let sliverHeight: CGFloat = 6

    /// One action button, edge to edge, and the gap between two.
    static let actionButtonSize: CGFloat = 28
    static let actionSpacing: CGFloat = 4
    /// Never more than this many glyphs on the picture, even on a wide card.
    ///
    /// A second row of buttons is how a thumbnail becomes a control panel. Extra actions
    /// go in More, the context menu, and keyboard shortcuts.
    static let maxVisibleActions = 4
    /// How far the chrome is inset from the card's edge.
    ///
    /// Enough to clear the corner radius, so a button in a corner is not shaved by the
    /// rounded clip the card draws itself with.
    static let chromeInset: CGFloat = 8

    /// How many action buttons fit across a card of this width.
    static func actionsPerRow(width: CGFloat) -> Int {
        let available = width - chromeInset * 2
        let stride = actionButtonSize + actionSpacing
        guard available > 0, stride > 0 else { return 1 }
        return max(1, Int((available + actionSpacing) / stride))
    }

    /// The actions that sit on the thumbnail, and the ones that fold into More.
    static func splitActions(_ actions: [CardAction], width: CGFloat) -> (
        visible: [CardAction],
        overflow: [CardAction]
    ) {
        let cap = min(actionsPerRow(width: width), maxVisibleActions)
        guard actions.count > cap else {
            return (actions, [])
        }
        let visibleCount = max(cap - 1, 1)
        return (Array(actions.prefix(visibleCount)), Array(actions.dropFirst(visibleCount)))
    }

    /// Proportional to the width, not a constant.
    ///
    /// The height used to be a fixed 104 points at any width. The width is a setting that
    /// ranges from 140 to 420, so at the top of that range the card was a letterbox slot
    /// showing a horizontal strip cropped out of the middle of the capture — the setting
    /// made the card wider without making it show any more.
    static func height(forWidth width: CGFloat) -> CGFloat {
        (width * 0.66).rounded()
    }

    private var height: CGFloat {
        Self.height(forWidth: width)
    }

    /// Hover chrome is suppressed while the stack is moving.
    private var showsChrome: Bool {
        (isHovering || alwaysShowActions || isExpanded || isFocused) && !suppressHoverChrome
    }

    var isCompact: Bool {
        width <= 160
    }

    /// Every action this card's layout offers, in stable order.
    private var configuredActions: [CardAction] {
        CardSlot.allCases.flatMap { layout.actions(in: $0, for: item.captureKind) }
    }

    /// Layout actions first, then the ones that still apply but are not on the picture.
    ///
    /// The daily row is short on purpose. Pin, OCR, Trim and the rest stay reachable from
    /// the context menu and VoiceOver so simplifying the thumbnail does not hide them.
    private var reachableActions: [CardAction] {
        let onCard = configuredActions
        let rest = CardAction.allCases.filter {
            $0.applies(to: item.captureKind) && !onCard.contains($0)
        }
        return onCard + rest
    }

    /// Chrome fades for hover, and simply goes when the stack starts moving.
    ///
    /// Double-clicking a card opens the editor, which tucks the stack into the peek tab — so
    /// the card slides away while its own chrome is still fading out over the top. Two
    /// animations of different lengths on the same view, one of them on something leaving the
    /// screen. The slide is the one worth watching.
    private var chromeAnimation: Animation? {
        guard !reduceMotion, !suppressHoverChrome else { return nil }
        return KadrMotion.press
    }

    var body: some View {
        card
            .animation(chromeAnimation, value: showsChrome)
            .focusable()
            // The system ring is a rectangle around a rounded picture; the card draws its own.
            .focusEffectDisabled()
            .focused($isFocused)
            .onChange(of: requestsKeyboardFocus, initial: true) { _, requested in
                if requested {
                    isFocused = true
                }
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    actions.keyboardFocused()
                }
            }
            .onHover { hovering in
                isHovering = hovering
                actions.setHovered(hovering)
            }
            .contextMenu { contextMenu }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Capture \(item.filename), \(item.dimensionsText)")
            .accessibilityHint(accessibilityHint)
            .accessibilityActions { accessibilityActions }
    }

    private var accessibilityHint: String {
        if showsChrome {
            return "Actions shown. Open it to annotate, or drag it to another app."
        }
        // macOS wording: VoiceOver on the Mac has no taps (docs/17 T-OUT-13).
        return "Click to show actions and give the card the keyboard, or drag it to another app."
    }

    @ViewBuilder
    private var contextMenu: some View {
        ForEach(reachableActions.filter { $0 != .delete }, id: \.self) { cardAction in
            switch cardAction {
            case .share:
                ShareLink(item: item.fileURL) {
                    Text("Share")
                }
                .accessibilityLabel("Share \(item.filename)")
            default:
                Button(cardAction.title) {
                    perform(cardAction)
                }
            }
        }
        if !item.isVideo {
            Divider()
            Button("Rotate 90°", action: actions.rotate)
            Button("Flip Horizontal", action: actions.flipHorizontal)
            Button("Flip Vertical", action: actions.flipVertical)
            if item.canScaleRetina {
                Button("Scale Retina to 1×", action: actions.scaleRetina)
            }
        }
        Divider()
        Text(item.dimensionsText)
        if let size = item.fileSizeText {
            Text(size)
        }
        Divider()
        Button("Hide", action: actions.dismiss)
        if actions.deleteAvailable {
            Button("Move to Trash", role: .destructive, action: actions.delete)
        }
    }

    @ViewBuilder
    private var accessibilityActions: some View {
        ForEach(reachableActions.filter { $0 != .delete }, id: \.self) { cardAction in
            Button(cardAction.title) {
                perform(cardAction)
            }
        }
        Button("Hide", action: actions.dismiss)
        if actions.deleteAvailable {
            Button("Move to Trash", action: actions.delete)
        }
    }

    /// The capture, the chrome over it, and the border and shadow around the pair.
    ///
    /// Split out of `body` because the whole thing in one chain stopped type-checking in
    /// reasonable time.
    private var card: some View {
        ThumbnailImage(
            url: item.fileURL,
            maxPixelSize: Int((width * displayScale).rounded()),
            isVideo: item.isVideo,
            revision: item.contentRevision
        )
        .frame(width: width, height: height)
        // Rounded at the source as well as by the outer clip: during a compound animation
        // (the stack reflowing while a card slides) the outer clip can lag a frame and flash
        // square corners past the rounded card.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // One AppKit view owns click, double-click and drag. A file promise rather than a
        // URL, so a staged capture is finalised when the receiver asks for it and an
        // abandoned drag changes nothing (docs/03 §2, §6; docs/09 U0.1).
        .overlay(dragSurface)
        // Above the drag view, so the buttons take their own clicks. The scrim behind them
        // does not, which is what keeps a hovered card draggable.
        .overlay {
            if showsChrome {
                hoverChrome
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // Two hairlines: a dark one that holds the edge against a light desktop, and a faint
        // light one inside it that holds the edge of a dark capture against a dark desktop.
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(KadrAccessibility.increaseContrast ? 0.5 : 0.16), lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius - 0.5, style: .continuous)
                .inset(by: 0.5)
                .strokeBorder(Color.white.opacity(KadrAccessibility.increaseContrast ? 0.45 : 0.18), lineWidth: 0.5)
        )
        // Flattened first, so the shadow is cast by the rounded result rather than by the
        // square image inside it.
        .compositingGroup()
        .kadrShadow(.floating)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Self.cornerRadius + 3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            // The hover chrome puts the size pill in this corner, so the dot steps aside.
            if showsNewestIndicator, !showsChrome {
                newestIndicator
                    .transition(.opacity)
            }
        }
    }

    /// Marks the card the user just captured when several are stacked (CleanShot §6.3).
    private var newestIndicator: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 9, height: 9)
            .overlay(
                Circle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
            )
            .kadrShadow(.glyph)
            .padding(9)
            .accessibilityLabel("Newest capture")
            .help("Your most recent capture")
    }

    private var dragSurface: some View {
        FilePromiseDragView(
            payload: {
                FilePromisePayload(
                    suggestedName: item.filename,
                    contentType: item.contentType,
                    resolve: actions.resolveForDrag,
                    completed: actions.dragCompleted,
                    // Where the capture is right now — the staging folder for a card that
                    // has not been acted on yet. Promise-aware receivers never look at it,
                    // but the many that only read `public.file-url` (browsers, Electron
                    // apps) got nothing at all without it (docs/16 OUT-6).
                    stableFileURL: item.fileURL,
                    pathHandedOut: actions.pathHandedOut
                )
            },
            dragImage: {
                ThumbnailLoader().thumbnail(for: item.fileURL, maxPixelSize: 256).map {
                    NSImage(cgImage: $0, size: .zero)
                }
            },
            onTap: {
                isExpanded.toggle()
            },
            onDoubleTap: {
                if item.isVideo {
                    if actions.studioAvailable {
                        actions.studio()
                    } else if let reason = actions.unavailableReason(.studio) {
                        actions.reportUnavailable(reason)
                    }
                } else if actions.annotateAvailable {
                    actions.annotate()
                } else if let reason = actions.unavailableReason(.annotate) {
                    actions.reportUnavailable(reason)
                }
            },
            onDragBegan: { actions.beginDrag() }
        )
    }
}
