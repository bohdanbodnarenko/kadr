import AppKit
import CoreGraphics
import ImageIO
import os
import Shared

/// Runs OCR on a capture and hands back everything the UI needs (docs/03 §1.7, §3).
///
/// One place rather than three: the selection overlay's "capture text" mode, a card's Copy
/// Text and a pin's Copy Text all want the same thing — recognised text on the clipboard
/// and a toast showing what was found. Cards and pins had the button but no implementation
/// at all (docs/07 M8), and copying the coordinator's version twice more would have been
/// three chances to forget `disconnect()`.
///
/// The recognition itself runs in the Vision helper, which the agent talks to over XPC and
/// then drops so the helper can start its idle countdown and give its models back
/// (docs/04 §1). The agent never links VisionServices.
@MainActor
final class TextRecognizer {
    /// What one recognition found.
    struct Recognition {
        var text: String
        var codes: [DetectedCode]
        var table: RecognizedTable?

        var isEmpty: Bool {
            text.isEmpty && codes.isEmpty
        }
    }

    private let vision = VisionClient()
    private let logger = KadrLog.logger(.capture)

    /// Recognises text in an image already in memory.
    func recognize(_ image: CGImage, preservingLineBreaks: Bool) async throws -> Recognition {
        defer { vision.disconnect() }
        let analysis = try await vision.analyze(
            image,
            options: TextRecognitionOptions(preservesLineBreaks: preservingLineBreaks)
        )
        return Recognition(
            text: analysis.text(preservingLineBreaks: preservingLineBreaks),
            codes: analysis.codes,
            table: analysis.primaryTable
        )
    }

    /// Recognises text in a capture on disk.
    ///
    /// Decoding happens here, at full resolution: OCR quality falls off quickly with
    /// downsampling, and this is a one-shot user action rather than anything on a hot path.
    func recognize(fileAt url: URL, preservingLineBreaks: Bool) async throws -> Recognition {
        if let image = Self.decode(url) {
            return try await recognize(image, preservingLineBreaks: preservingLineBreaks)
        }
        if let frame = await VideoPosterFrame.still(of: url) {
            return try await recognize(frame, preservingLineBreaks: preservingLineBreaks)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// Puts recognised text on the clipboard. Returns whether there was anything to put.
    @discardableResult
    func copyToClipboard(_ recognition: Recognition) -> Bool {
        guard !recognition.text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recognition.text, forType: .string)
        return true
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
