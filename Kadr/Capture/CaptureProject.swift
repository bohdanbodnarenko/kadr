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
        let encoder = ImageEncoder()
        let options = EncodingOptions(format: .png, scale: original.metadata.scale)
        guard let png = try? encoder.encode(original.image, options: options) else { return }
        let scale = original.metadata.scale.factor
        let size = CGSize(
            width: CGFloat(original.image.width) / scale,
            height: CGFloat(original.image.height) / scale
        )
        var document = AnnotationDocument(
            baseImage: BaseImageReference(size: size, scale: scale)
        )
        if let look = DefaultCaptureLook.load() {
            document.applyStylePreset(look)
        }
        if let beautify {
            document.setBeautify(beautify)
        }
        guard !document.commands.isEmpty else { return }
        try? KadrDocumentFile.write(
            KadrDocumentFile.Contents(document: document, baseImagePNG: png),
            to: url(alongside: flattenedURL)
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
