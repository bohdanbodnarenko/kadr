import AnnotationModel
import CoreGraphics
import Foundation

/// Modal crop: the full capture stays on screen with an overlay, the way Screendrop
/// crops, rather than shrinking the canvas as the rect is dragged (docs/09 U1.8).
public extension EditorDocumentModel {
    /// The rect the overlay draws and the handles grab. Before the first drag this is
    /// the whole capture, so entering Crop is immediately interactive.
    var cropWorkingRect: CGRect {
        document.crop?.rect ?? document.baseImage.bounds
    }

    /// Handle hit in image space, with a view-constant tolerance passed from the canvas.
    func cropHandle(at point: CGPoint, tolerance: CGFloat) -> CropHandle? {
        CropRectEditor.handle(at: point, in: cropWorkingRect, tolerance: max(tolerance, CropRectEditor.handleTolerance))
    }

    func beginCropDrag(at point: CGPoint, grabbing: CropHandle?, handleTolerance: CGFloat) {
        let handle = grabbing ?? cropHandle(at: point, tolerance: handleTolerance)
        // Interior-drag on a crop that already fills the capture is a no-op move. Treat
        // that — and a click in the dimmed exterior — as rubber-banding a new rect, which
        // is how Crop is expected to work when it is armed like the other drawing tools.
        if handle == nil || (handle == .body && isFullCaptureCrop) {
            cropDragHandle = .bottomTrailing
            cropDragStartRect = CGRect(origin: point, size: .zero)
            document.beginGesture()
            return
        }
        guard let handle else { return }
        cropDragHandle = handle
        cropDragStartRect = cropWorkingRect
        document.beginGesture()
    }

    private var isFullCaptureCrop: Bool {
        let bounds = document.baseImage.bounds
        let working = cropWorkingRect
        return working.insetBy(dx: -0.5, dy: -0.5).contains(bounds)
            && bounds.insetBy(dx: -0.5, dy: -0.5).contains(working)
    }

    func dragCrop(to point: CGPoint, from origin: CGPoint, modifiers: EditorModifiers) {
        guard let handle = cropDragHandle, let start = cropDragStartRect else { return }
        let translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        let aspect = cropAspectForDrag(handle: handle, start: start, modifiers: modifiers)
        let expand = document.crop?.canExpandCanvas ?? false
        let next = CropRectEditor.resized(
            start,
            handle: handle,
            translation: translation,
            aspect: aspect,
            bounds: expand ? nil : document.baseImage.bounds
        )
        var spec = document.crop ?? CropSpec(rect: next)
        spec.rect = next
        document.setCrop(spec)
    }

    /// Corners follow the inspector ratio; ⇧ on a free crop locks the starting aspect.
    private func cropAspectForDrag(
        handle: CropHandle,
        start: CGRect,
        modifiers: EditorModifiers
    ) -> CGFloat? {
        guard handle != .body else { return nil }
        if let ratio = cropAspect.ratio(original: document.baseImage.size) {
            return ratio
        }
        if modifiers.contains(.constrain), start.height > 0 {
            return start.width / start.height
        }
        return nil
    }
}
