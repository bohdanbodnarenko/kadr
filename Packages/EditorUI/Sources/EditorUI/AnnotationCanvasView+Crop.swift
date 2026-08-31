import AnnotationModel
import AppKit
import QuartzCore

/// Modal crop chrome: dimmed exterior, rule-of-thirds, white border, eight handles
/// (Screendrop's `AnnotationCropOverlay`, drawn with CALayer so the mouse path stays AppKit).
extension AnnotationCanvasView {
    func updateCropOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        cropLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        cropLayer.isHidden = model.tool != .crop
        guard model.tool == .crop else { return }

        let rect = model.cropWorkingRect
        let imageBounds = model.document.baseImage.bounds
        let scale = handleViewScale

        let dim = CAShapeLayer()
        let dimPath = CGMutablePath()
        dimPath.addRect(imageBounds)
        dimPath.addRect(rect)
        dim.path = dimPath
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        cropLayer.addSublayer(dim)

        let grid = CAShapeLayer()
        let gridPath = CGMutablePath()
        for index in 1 ... 2 {
            let x = rect.minX + rect.width * CGFloat(index) / 3
            gridPath.move(to: CGPoint(x: x, y: rect.minY))
            gridPath.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * CGFloat(index) / 3
            gridPath.move(to: CGPoint(x: rect.minX, y: y))
            gridPath.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        grid.path = gridPath
        grid.fillColor = nil
        grid.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        grid.lineWidth = 0.75 / scale
        cropLayer.addSublayer(grid)

        let border = CAShapeLayer()
        border.path = CGPath(rect: rect, transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1.5 / scale
        border.shadowOpacity = 0.35
        border.shadowRadius = 1 / scale
        border.shadowOffset = .zero
        border.shadowColor = NSColor.black.cgColor
        cropLayer.addSublayer(border)

        let handles = model.cropAspect == .free
            ? CropHandle.resizeHandles
            : CropHandle.resizeHandles.filter(\.isCorner)
        let size = SelectionResizer.cornerSize / scale
        for handle in handles {
            cropLayer.addSublayer(handleSquare(at: handle.point(in: rect), size: size))
        }
    }

    /// Crop handle under the event, in window points so it stays hittable when zoomed out.
    func screenSpaceCropHandle(at event: NSEvent) -> CropHandle? {
        guard model.tool == .crop else { return nil }
        let click = event.locationInWindow
        let radius = SelectionResizer.hitRadius
        let rect = model.cropWorkingRect
        let handles = model.cropAspect == .free
            ? CropHandle.resizeHandles
            : CropHandle.resizeHandles.filter(\.isCorner)
        for handle in handles {
            let canvas = viewPoint(fromImage: handle.point(in: rect))
            let window = convert(canvas, to: nil)
            if hypot(click.x - window.x, click.y - window.y) <= radius {
                return handle
            }
        }
        let imagePoint = imagePoint(fromWindowPoint: event.locationInWindow)
        return rect.contains(imagePoint) ? .body : nil
    }
}
