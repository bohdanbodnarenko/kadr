import AnnotationModel
import Foundation
import HistoryKit
import ImageIO
import os
import Shared
import UniformTypeIdentifiers

/// Putting a `.kadr` project into the capture library (docs/03 §5, docs/06 M24).
///
/// A project is a zip, so ImageIO cannot thumbnail it. The base image inside it can be —
/// which is also the honest thumbnail: what a project looks like in the library should be
/// the screenshot it is built on, not a generic document icon.
///
/// The agent does this rather than the editor because the library belongs to the agent;
/// the editor asks for it through `kadr://add-to-history` (docs/03 §8.4).
@MainActor
struct ProjectIngest {
    private let logger = KadrLog.logger(.history)

    /// Builds the ingest record for a file, whatever kind it is.
    ///
    /// - Returns: nil when the file cannot be read as something the library can hold.
    func draft(for url: URL) -> HistoryIngest? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.pathExtension.lowercased() == KadrDocumentFile.fileExtension
            ? projectDraft(for: url)
            : imageDraft(for: url)
    }

    /// A `.kadr`: read the base image out of the zip for the size and the thumbnail.
    private func projectDraft(for url: URL) -> HistoryIngest? {
        guard let contents = try? KadrDocumentFile.read(from: url) else {
            logger.error("Could not read \(url.lastPathComponent, privacy: .public) as a project")
            return nil
        }
        let size = contents.document.baseImage.pixelSize
        return HistoryIngest(
            sourceURL: url,
            kind: .project,
            pixelSize: PixelSize(width: Int(size.width), height: Int(size.height)),
            capturedAt: Date(),
            originalFilename: url.lastPathComponent,
            thumbnailSourceURL: writeThumbnailSource(contents.baseImagePNG)
        )
    }

    private func imageDraft(for url: URL) -> HistoryIngest? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            logger.error("Could not read \(url.lastPathComponent, privacy: .public) as an image")
            return nil
        }
        return HistoryIngest(
            sourceURL: url,
            kind: .image,
            pixelSize: PixelSize(width: width, height: height),
            capturedAt: Date(),
            originalFilename: url.lastPathComponent
        )
    }

    /// The base PNG, written where the thumbnail pipeline can read it.
    ///
    /// A scratch file rather than a permanent one: `HistoryStore` copies what it needs
    /// into the library, and this is gone by the next launch's staging sweep.
    private func writeThumbnailSource(_ png: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-project-\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            logger.error("Could not stage a project thumbnail: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
