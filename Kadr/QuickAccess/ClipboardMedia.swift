import AppKit
import Foundation
import UniformTypeIdentifiers

/// Reads a still or a movie off a pasteboard (CleanShot `open-from-clipboard`, 4.6).
enum ClipboardMedia {
    /// A PNG on disk for an image or a block of text on the pasteboard.
    static func stillPNGFile(from pasteboard: NSPasteboard) -> URL? {
        guard let png = stillPNG(from: pasteboard) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kadr-clipboard-\(UUID().uuidString).png")
        do {
            try png.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    /// Image bytes, or a card rendered from text / RTF / HTML.
    static func stillPNG(from pasteboard: NSPasteboard) -> Data? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            return textCardPNG(from: pasteboard)
        }
        return png
    }

    /// Draws clipboard text as a padded card so it can be pinned like a screenshot.
    static func textCardPNG(from pasteboard: NSPasteboard) -> Data? {
        let attributed: NSAttributedString? = if let data = pasteboard.data(forType: .rtf) {
            NSAttributedString(rtf: data, documentAttributes: nil)
        } else if let data = pasteboard.data(forType: .html) {
            try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            )
        } else if let string = plainText(from: pasteboard) {
            NSAttributedString(
                string: string,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15),
                    .foregroundColor: NSColor.labelColor
                ]
            )
        } else {
            nil
        }
        guard let attributed, attributed.length > 0 else { return nil }
        return renderCard(attributed)
    }

    private static func plainText(from pasteboard: NSPasteboard) -> String? {
        let string = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    static func renderCard(_ attributed: NSAttributedString) -> Data? {
        let maxWidth: CGFloat = 480
        let padding: CGFloat = 24
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let size = CGSize(
            width: ceil(bounds.width) + padding * 2,
            height: ceil(bounds.height) + padding * 2
        )
        guard size.width >= 1, size.height >= 1 else { return nil }
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 12, yRadius: 12).fill()
        attributed.draw(with: NSRect(
            x: padding,
            y: padding,
            width: bounds.width,
            height: bounds.height
        ), options: [.usesLineFragmentOrigin, .usesFontLeading])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A file URL already on the pasteboard, or movie bytes written to a temp file.
    static func fileURL(from pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = urls.first,
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            return movieFile(from: pasteboard)
        }
        return url
    }

    /// Movie data (QuickTime copy, some browsers) written next to other clipboard imports.
    static func movieFile(from pasteboard: NSPasteboard) -> URL? {
        for candidate in movieTypes {
            guard let data = pasteboard.data(forType: candidate.type), !data.isEmpty else { continue }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("Kadr-clipboard-\(UUID().uuidString).\(candidate.fileExtension)")
            do {
                try data.write(to: destination, options: .atomic)
                return destination
            } catch {
                continue
            }
        }
        return nil
    }

    private static var movieTypes: [(type: NSPasteboard.PasteboardType, fileExtension: String)] {
        [
            (NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier), "mp4"),
            (NSPasteboard.PasteboardType(UTType.quickTimeMovie.identifier), "mov"),
            (NSPasteboard.PasteboardType(UTType.movie.identifier), "mp4")
        ]
    }
}
