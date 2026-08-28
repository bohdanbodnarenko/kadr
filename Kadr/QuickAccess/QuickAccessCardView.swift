import AppKit
import HistoryKit
import Shared
import SwiftUI

/// What a card can do (docs/03 §2). Stubs are wired to the milestones that fill them in.
struct QuickAccessCardActions {
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var annotate: () -> Void = {}
    var pin: () -> Void = {}
    var recognizeText: () -> Void = {}
    var share: (NSView) -> Void = { _ in }
    var delete: () -> Void = {}
    var dismiss: () -> Void = {}
    /// Resolves the file to hand to a receiver, finalising a staged capture on the way.
    /// Called when the drop asks for the bytes, never when the drag starts (docs/07 C1).
    var resolveForDrag: @MainActor @Sendable () -> URL? = { nil }
    /// The drag ended; `true` when a receiver took the file.
    var dragCompleted: @MainActor @Sendable (Bool) -> Void = { _ in }
    /// Turns a recording into a GIF (docs/03 §1.8). Only offered on a recording.
    var exportGIF: () -> Void = {}
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

    @State private var isHovering = false
    @State private var isExpanded = false

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
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture \(item.filename), \(item.dimensionsText)")
    }

    private var thumbnail: some View {
        ThumbnailImage(url: item.fileURL, maxPixelSize: Int(width * 2), isVideo: item.isVideo)
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

    private var actionRow: some View {
        HStack(spacing: 2) {
            action("Copy", systemImage: "doc.on.doc", action: actions.copy)
            action("Save", systemImage: "square.and.arrow.down", action: actions.save)
            action(
                "Annotate",
                systemImage: "pencil.tip.crop.circle",
                enabled: actions.annotateAvailable,
                action: actions.annotate
            )
            if item.isVideo {
                // A recording gets GIF where a screenshot gets Pin and OCR; neither of
                // those means anything for a movie (docs/03 §1.8, §2).
                action("Export GIF", systemImage: "square.stack.3d.down.right", action: actions.exportGIF)
            } else {
                action("Pin", systemImage: "pin", enabled: actions.pinAvailable, action: actions.pin)
                action(
                    "Copy Text",
                    systemImage: "text.viewfinder",
                    enabled: actions.textAvailable,
                    action: actions.recognizeText
                )
            }
            ShareLink(item: item.fileURL) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("Share")
            action("Delete", systemImage: "trash", action: actions.delete)
        }
        .frame(height: Self.actionRowHeight)
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
