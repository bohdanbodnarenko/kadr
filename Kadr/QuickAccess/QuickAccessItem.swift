import CaptureCore
import CoreGraphics
import Foundation
import HistoryKit
import SettingsKit
import Shared
import UniformTypeIdentifiers

enum CardActivity: Equatable, Sendable {
    case compressing
    case recognizingText
    case exportingGIF

    var progressMessage: String {
        switch self {
        case .compressing: String(localized: "Compressing…")
        case .recognizingText: String(localized: "Reading text…")
        case .exportingGIF: String(localized: "Making a GIF…")
        }
    }
}

/// Whose file a card is showing, which decides what Save, transforms and Trash may do
/// with it (docs/17 T-OUT-5).
enum QuickAccessOrigin: Equatable, Sendable {
    /// A capture Kadr wrote: staged, or already in the save folder. Kadr may move,
    /// rewrite and trash it.
    case capture
    /// The History library's content-addressed copy. Moving or rewriting it breaks the
    /// History row, so every change works on a copy.
    case library
    /// A file the user already had: `add-quick-access-overlay`, Open from Clipboard. It is
    /// theirs; Kadr copies it and never trashes it.
    case external

    /// Whether Kadr may move, rewrite or trash the file in place.
    var ownsFile: Bool {
        self == .capture
    }
}

/// One capture, as the overlay knows it (docs/03 §2).
///
/// Note what is *not* here: the full-resolution image. The card holds a file URL and a
/// small thumbnail, and everything else — copying, dragging, annotating — goes back to
/// the file. That is doc 04 §7 rule 2, and it is why five cards cost megabytes rather
/// than hundreds.
struct QuickAccessItem: Identifiable, Sendable {
    let id = UUID()
    /// Where the capture lives right now: the staging area, or the save folder.
    var fileURL: URL
    /// True while the file is still in staging and has not been finalised (docs/03 §2).
    var isStaged: Bool
    var pixelSize: PixelSize
    /// Backing scale at capture time, so "Scale Retina to 1×" knows whether it applies.
    var scale: DisplayScale = .oneToOne
    /// Bumped when the file's pixels change in place, so the thumbnail reloads.
    var contentRevision = 0
    let capturedAt: Date
    let displayID: CGDirectDisplayID?
    /// True for a screen recording, whose card shows a poster frame and a play badge
    /// rather than a thumbnail (docs/03 §1.8).
    var isVideo = false

    /// Which row of the after-capture matrix and the card layout this item belongs to
    /// (docs/09 U2.2, U2.3).
    var captureKind: CaptureKind {
        isVideo ? .recording : .screenshot
    }

    /// How much smaller the last compression made it, or nil if it was not worth doing
    /// (docs/09 U2.4). Only set once `wasCompressed` is true.
    var compressionSavings: Double?
    /// Whether compression has been tried, so the badge can say "no smaller" rather than
    /// showing nothing and looking broken.
    var wasCompressed = false
    /// In-flight work that should pause auto-dismiss (docs/16 OUT-5, OUT-16).
    var activity: CardActivity?

    /// How HistoryKit should classify this capture (docs/03 §5).
    var historyKind: HistoryItemKind = .image
    /// The name to show on the card when the file on disk is content-addressed.
    var displayName: String?
    /// App that was in front when the capture was taken, stored with the history record.
    var applicationName: String?
    /// Whose file this is (docs/17 T-OUT-5).
    var origin: QuickAccessOrigin = .capture

    var filename: String {
        displayName ?? fileURL.lastPathComponent
    }

    /// What the file actually is, for pasteboard types and promise drags.
    ///
    /// Derived from the file rather than assumed: a capture may be PNG, JPEG, HEIC, WebP
    /// or an MP4, and telling the receiver it is a PNG when it is not is how a paste ends
    /// up as garbage (docs/07 M1).
    var contentType: UTType {
        UTType(filenameExtension: fileURL.pathExtension) ?? (isVideo ? .mpeg4Movie : .png)
    }

    /// "1280 × 960" for the hover readout.
    var dimensionsText: String {
        "\(pixelSize.width) × \(pixelSize.height)"
    }

    /// Whether the context menu should offer Scale Retina to 1× (CleanShot §6.2).
    var canScaleRetina: Bool {
        !isVideo && scale.factor > 1
    }

    /// File size on disk, formatted, or nil while the file is missing.
    var fileSizeText: String? {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
