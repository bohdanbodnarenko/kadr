import CoreGraphics
import Foundation
import StudioSession

/// Direct manipulation of the webcam bubble and a zoom's target (docs/09 U3.4).
public extension StudioDocumentModel {
    func moveCamera(toNormalizedCenter point: CGPoint) {
        change(coalescingAs: "camera.move") {
            $0.camera.move(toNormalizedCenter: point)
        }
    }

    func snapCamera(to placement: BubblePlacement) {
        change { $0.camera.snap(to: placement) }
    }

    func resizeCamera(toSizeFraction value: Double, pinningTopLeading origin: CGPoint) {
        change(coalescingAs: "camera.size") {
            $0.camera.resize(toSizeFraction: value, pinningTopLeading: origin, in: manifest.pixelSize)
        }
    }

    /// Pixel-space target for a cue, written from a normalised pad drag.
    func setZoomAnchor(_ id: ZoomCue.ID, toNormalized point: CGPoint) {
        let size = manifest.pixelSize
        let pixel = CGPoint(
            x: min(max(point.x, 0), 1) * size.width,
            y: min(max(point.y, 0), 1) * size.height
        )
        updateZoom(id, coalescingAs: "zoom.anchor.\(id)") { $0.anchor = .fixed(pixel) }
    }

    func normalizedZoomAnchor(for id: ZoomCue.ID) -> CGPoint {
        guard let cue = edit.zooms.first(where: { $0.id == id }) else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let size = manifest.pixelSize
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let pixel = cue.anchor.point(in: size)
        return CGPoint(x: pixel.x / size.width, y: pixel.y / size.height)
    }
}
