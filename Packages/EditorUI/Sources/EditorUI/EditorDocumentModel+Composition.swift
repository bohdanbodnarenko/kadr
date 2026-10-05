import AnnotationModel
import CoreGraphics
import Foundation

/// Building a composition out of more than one capture (docs/03 §3 P2, docs/06 M24).
public extension EditorDocumentModel {
    /// The selected image, when exactly one is selected — what the inspector edits.
    var selectedImage: ImageSpec? {
        guard selection.count == 1, let id = selection.first else { return nil }
        if case let .image(spec) = document.command(id) {
            return spec
        }
        return nil
    }

    /// Places an image on the canvas and selects it.
    ///
    /// - Parameters:
    ///   - pngData: the image, already encoded. The editor never holds a second decoded
    ///     bitmap for it — the render layer decodes on demand and caches.
    ///   - pixelSize: the image's own pixel size, used to size it sensibly.
    ///   - point: where the user dropped it, in base-image points.
    @discardableResult
    func insertImage(pngData: Data, pixelSize: CGSize, at point: CGPoint) -> AnnotationID? {
        guard !pngData.isEmpty, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let rect = ImageSpec.placement(
            pixelSize: pixelSize,
            scale: document.baseImage.scale,
            droppedAt: point,
            in: document.contentRect
        )
        guard !rect.isEmpty else { return nil }

        let spec = ImageSpec(
            pngData: pngData,
            rect: rect,
            hasShadow: EditorCanvasPreferences.objectShadowsEnabled()
        )
        let command = AnnotationCommand.image(spec)
        document.add(command)
        document.selection = [command.id]
        return command.id
    }

    /// Applies an edit to the selected image. One undo step per change.
    func updateSelectedImage(_ transform: (inout ImageSpec) -> Void) {
        guard var spec = selectedImage else { return }
        transform(&spec)
        let id = spec.id
        document.perform { commands in
            guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
            commands[index] = .image(spec)
        }
    }

    /// Applies a slider edit to the selected image. Successive calls amend one undo step
    /// until `endInspectorStyleEdit`, so a long drag neither evicts earlier history nor
    /// makes ⌘Z walk back tick by tick (docs/18 ED-4).
    func updateSelectedImageLive(_ transform: (inout ImageSpec) -> Void) {
        guard let id = selectedImage?.id else { return }
        rewriteSelectionLive { command in
            guard command.id == id, case var .image(spec) = command else { return command }
            transform(&spec)
            return .image(spec)
        }
    }
}
