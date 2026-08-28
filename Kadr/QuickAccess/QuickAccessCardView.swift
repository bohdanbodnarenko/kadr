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
    /// The user has touched this card, so it stops closing on its own (docs/09 U2.1).
    var engage: () -> Void = {}
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
    @State private var isExpanded = false
    /// The scale of the screen this card is on.
    ///
    /// Read rather than assumed: hard-coding 2× decoded twice the pixels needed on a
    /// non-Retina display, and — once Apple ships anything above 2× — too few on a better
    /// one (docs/07 LOW).
    @Environment(\.displayScale) private var displayScale

    private static let thumbnailHeight: CGFloat = 120
    private static let actionRowHeight: CGFloat = 36
    private static let padding: CGFloat = 8

    /// The panel needs its height before SwiftUI has laid anything out.
    static func height(forWidth width: CGFloat, item: QuickAccessItem) -> CGFloat {
        thumbnailHeight + actionRowHeight + padding * 2
    }

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
            if isExpanded {
                actionRow
            } else {
                details
            }
        }
        .padding(Self.padding)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .onHover { hovering in
            isHovering = hovering
            // Hovering counts: reaching for a card is working with it, and having it
            // vanish mid-thought is what makes people turn auto-close off entirely.
            if hovering {
                actions.engage()
            }
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
                onTap: { isExpanded.toggle() },
                onDoubleTap: {
                    if actions.annotateAvailable {
                        actions.annotate()
                    }
                }
            )
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to expand actions, or drag to another app")
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
            if item.isStaged {
                Image(systemName: "tray")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Kept in the overlay only. Saved when you act on it.")
            }
        }
        .frame(height: Self.actionRowHeight)
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

    /// The corner buttons, which are always visible.
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
        default: true
        }
    }

    private func handler(for cardAction: CardAction) -> () -> Void {
        switch cardAction {
        case .copy: actions.copy
        case .save: actions.save
        case .annotate: actions.annotate
        case .pin: actions.pin
        case .recognizeText: actions.recognizeText
        case .trim: actions.trim
        case .exportGIF: actions.exportGIF
        case .compress: actions.compress
        case .delete: actions.delete
        case .share: {}
        }
    }

    private func action(
        _ title: String,
        systemImage: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
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
