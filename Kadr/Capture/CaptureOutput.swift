import AppKit
import CaptureCore
import ImageIO
import os
import Shared
import UniformTypeIdentifiers

/// Where a finished capture goes.
///
/// A stub until M4 brings MediaExport and M5 the Quick Access Overlay: for now every
/// capture lands on the clipboard, which is the clipboard-first default from docs/03
/// §8.3 and enough to prove the pipeline end to end.
@MainActor
struct CaptureOutput {
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    /// Puts a capture on the clipboard as PNG.
    ///
    /// PNG rather than TIFF because that is what other apps paste losslessly, and as
    /// data rather than an `NSImage` so no resampling can creep in.
    @discardableResult
    func copyToClipboard(_ image: CGImage) -> Bool {
        let state = signposter.beginInterval("copyToClipboard")
        defer { signposter.endInterval("copyToClipboard", state) }

        guard let data = pngData(from: image) else {
            logger.error("Could not encode the capture as PNG")
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrote = pasteboard.setData(data, forType: .png)
        logger.info("Copied \(image.width, privacy: .public)×\(image.height, privacy: .public) px to the clipboard")
        return wrote
    }

    /// Delivers a whole-screen capture, which on a multi-display desk is several images
    /// (docs/03 §1.3).
    ///
    /// One image can go on the clipboard, so the rest are written to the save folder.
    /// M4 replaces this with MediaExport's format, template and policy handling; the
    /// behaviour here is deliberately the simplest thing that loses no capture.
    func deliver(_ captures: [Capture]) {
        guard let first = captures.first else { return }
        copyToClipboard(first.image)

        guard captures.count > 1 else { return }
        for capture in captures {
            write(capture)
        }
    }

    /// Writes a PNG next to the user's other screenshots, never overwriting.
    @discardableResult
    func write(_ capture: Capture, to folder: URL? = nil) -> URL? {
        let directory = folder ?? FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())

        guard let data = pngData(from: capture.image) else {
            logger.error("Could not encode a capture as PNG")
            return nil
        }

        let stamp = Self.filenameFormatter.string(from: capture.metadata.capturedAt)
        var url = directory.appendingPathComponent("Kadr \(stamp).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("Kadr \(stamp) (\(counter)).png")
            counter += 1
        }

        do {
            // Atomic, so a crash mid-write never leaves a truncated screenshot.
            try data.write(to: url, options: .atomic)
            logger.info("Wrote \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            logger.error("Could not write the capture: \(error.localizedDescription)")
            return nil
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    private func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
