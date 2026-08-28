import CaptureCore
import CoreGraphics
import Foundation
import HistoryKit
import SettingsKit
import Shared
import UniformTypeIdentifiers

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
    let pixelSize: PixelSize
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

    /// How HistoryKit should classify this capture (docs/03 §5).
    var historyKind: HistoryItemKind = .image
    /// The name to show on the card when the file on disk is content-addressed.
    var displayName: String?
    /// App that was in front when the capture was taken, stored with the history record.
    var applicationName: String?

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

    /// File size on disk, formatted, or nil while the file is missing.
    var fileSizeText: String? {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
