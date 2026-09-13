import AppKit
import Foundation
import UniformTypeIdentifiers

/// Reads a still or a movie off a pasteboard (CleanShot `open-from-clipboard`, 4.6).
enum ClipboardMedia {
    /// A file URL already on the pasteboard, or movie bytes written to a temp file.
    static func fileURL(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first,
           url.isFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return movieFile(from: pasteboard)
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
