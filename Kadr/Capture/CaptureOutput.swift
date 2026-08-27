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
