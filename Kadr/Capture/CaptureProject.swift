import AnnotationModel
import CaptureCore
import CoreGraphics
import Foundation
import MediaExport
import Shared

/// A sibling `.kadr` next to a flattened PNG, so window backdrops and auto-beautify
/// stay editable in the editor (docs/03 §1.2, §3 P2).
///
/// The overlay, clipboard and drag still use the flattened image. Annotate opens this
/// project when it exists, which is how the backdrop remains chrome rather than pixels.
enum CaptureProject {
    static func url(alongside imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension(KadrDocumentFile.fileExtension)
    }

    /// Writes `original` plus canvas chrome next to the flattened file the overlay shows.
    static func write(
        original: Capture,
        beautify: BeautifySpec?,
        alongside flattenedURL: URL
    ) {
        guard let document = document(for: original, beautify: beautify) else { return }
        encodeAndWrite(
            document,
            image: original.image,
            scale: original.metadata.scale,
            to: url(alongside: flattenedURL)
        )
    }

    /// The same, with the PNG encode off the main actor (T-CAP-7).
    ///
    /// Most captures need no project at all, and they now return before any encoding: the
    /// full-resolution original used to be PNG-encoded a second time on main for every
    /// capture — hundreds of milliseconds at 5K, inside the selection→clipboard budget —
    /// only to be thrown away when there was no look and no beautify to keep editable.
    static func writeOffMain(
        original: Capture,
        beautify: BeautifySpec?,
        alongside flattenedURL: URL
    ) async {
        guard let document = document(for: original, beautify: beautify) else { return }
        let image = original.image
        let scale = original.metadata.scale
        let target = url(alongside: flattenedURL)
        await Task.detached(priority: .utility) {
            encodeAndWrite(document, image: image, scale: scale, to: target)
        }.value
    }

    /// The project's document, or nil when there is nothing to keep editable.
    static func document(
        for original: Capture,
        beautify: BeautifySpec?,
        look: StylePreset? = DefaultCaptureLook.load()
    ) -> AnnotationDocument? {
        let scale = original.metadata.scale.factor
        let size = CGSize(
            width: CGFloat(original.image.width) / scale,
            height: CGFloat(original.image.height) / scale
        )
        var document = AnnotationDocument(
            baseImage: BaseImageReference(size: size, scale: scale)
        )
        if let look {
            document.applyStylePreset(look)
        }
        if let beautify {
            document.setBeautify(beautify)
        }
        return document.commands.isEmpty ? nil : document
    }

    private nonisolated static func encodeAndWrite(
        _ document: AnnotationDocument,
        image: CGImage,
        scale: DisplayScale,
        to target: URL
    ) {
        let options = EncodingOptions(format: .png, scale: scale)
        guard let png = try? ImageEncoder().encode(image, options: options) else { return }
        try? KadrDocumentFile.write(
            KadrDocumentFile.Contents(document: document, baseImagePNG: png),
            to: target
        )
    }

    /// The editor should open the project when one exists, otherwise the image itself.
    static func editorURL(for imageURL: URL) -> URL {
        let project = url(alongside: imageURL)
        return FileManager.default.fileExists(atPath: project.path) ? project : imageURL
    }

    /// Keeps the project next to the PNG when staging is finalised.
    static func move(from imageURL: URL, to newImageURL: URL) {
        let source = url(alongside: imageURL)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = url(alongside: newImageURL)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: source, to: destination)
    }

    static func trash(alongside imageURL: URL) {
        let project = url(alongside: imageURL)
        guard FileManager.default.fileExists(atPath: project.path) else { return }
        try? FileManager.default.trashItem(at: project, resultingItemURL: nil)
    }
}
