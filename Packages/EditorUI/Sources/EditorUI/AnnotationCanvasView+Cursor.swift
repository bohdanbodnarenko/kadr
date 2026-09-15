import AnnotationModel
import AppKit

extension AnnotationCanvasView {
    var canvasCursor: NSCursor {
        if spaceIsDown {
            return spacePanAnchor == nil ? NSCursor.openHand : NSCursor.closedHand
        }
        switch model.tool {
        case .select:
            if model.isMovingSelection {
                return NSCursor.closedHand
            }
            if let point = lastHoverImagePoint,
               AnnotationHitTesting.topmost(in: model.document.commands, at: point) != nil {
                return NSCursor.openHand
            }
            return NSCursor.arrow
        case .text:
            return NSCursor.iBeam
        case .crop:
            return NSCursor.crosshair
        default:
            return NSCursor.crosshair
        }
    }
}
