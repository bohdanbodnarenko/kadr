import AnnotationModel
import AppKit
import CoreGraphics
import QuartzCore

extension AnnotationCanvasView {
    /// Sizes the view to the oriented canvas and rotates the drawing host to match
    /// (docs/03 §3 P2). Layout always runs in unoriented space first.
    func applyCanvasOrientation() {
        let orientation = model.document.orientation
        let unoriented = bounds.size
        drawingHost.bounds = CGRect(origin: .zero, size: unoriented)
        drawingHost.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        guard !orientation.isIdentity else {
            drawingHost.position = CGPoint(x: unoriented.width / 2, y: unoriented.height / 2)
            drawingHost.setAffineTransform(.identity)
            return
        }

        let oriented = orientation.orientedSize(of: unoriented)
        setFrameSize(oriented)
        drawingHost.position = CGPoint(x: oriented.width / 2, y: oriented.height / 2)
        drawingHost.setAffineTransform(orientation.viewTransform())
    }

    /// Maps a click on the view onto image-space points (beautify offsets the card).
    func imagePoint(from event: NSEvent) -> CGPoint {
        imagePoint(fromWindowPoint: event.locationInWindow)
    }

    /// The same mapping from a bare window point.
    func imagePoint(fromWindowPoint windowPoint: CGPoint) -> CGPoint {
        var viewPoint = convert(windowPoint, from: nil)
        let unoriented = model.tool == .crop
            ? model.document.baseImage.size
            : model.document.canvasRect.size
        viewPoint = model.document.orientation.unapply(viewPoint, unoriented: unoriented)

        // A tilted capture is still editable, because the click is traced back through the
        // camera's inverse before anything else looks at it. Without this, clicking a
        // shape on a leaning screenshot selects whatever sits at the same *screen* point
        // on the upright one (docs/09 U1.2).
        if let camera = model.document.cameraGeometry {
            guard let unprojected = camera.contentPoint(from: viewPoint) else { return viewPoint }
            viewPoint = unprojected
        }

        // Crop mode shows the full capture so the overlay can dim the exterior. Mapping
        // through `contentRect` would jump the pointer into the already-cropped space.
        if model.tool == .crop {
            return viewPoint
        }
        return model.document.imagePoint(fromCanvas: viewPoint)
    }

    /// Image-space point as a point in this view, honouring crop-mode's full-capture layout.
    func viewPoint(fromImage point: CGPoint) -> CGPoint {
        if model.tool == .crop {
            return point
        }
        return model.document.canvasPoint(fromImage: point)
    }
}
