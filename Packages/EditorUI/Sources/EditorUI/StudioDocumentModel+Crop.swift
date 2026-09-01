import AnnotationModel
import CoreGraphics
import Foundation
import StudioSession

/// Crop as a mode on the studio preview, not four sliders (docs/09 U3.3).
///
/// The full recording stays on screen so a crop can grow as well as shrink. Committing
/// writes `edit.cropRect`; cancelling leaves the edit alone.
public extension StudioDocumentModel {
    func beginCrop() {
        guard !isCropping else { return }
        pausePlayback()
        workingCrop = edit.cropRect ?? StudioCropGeometry.unit
        cropAspect = .free
        isCropping = true
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        workingCrop = edit.cropRect ?? StudioCropGeometry.unit
        cropAspect = .free
    }

    func applyCrop() {
        guard isCropping else { return }
        let next = StudioCropGeometry.clamped(workingCrop)
        isCropping = false
        cropAspect = .free
        change {
            $0.cropRect = StudioCropGeometry.isFullFrame(next) ? nil : next
        }
    }

    func resetWorkingCrop() {
        guard isCropping else { return }
        workingCrop = StudioCropGeometry.unit
        applyCropAspect(cropAspect)
    }

    func applyCropAspect(_ preset: CropAspectPreset) {
        cropAspect = preset
        guard isCropping else { return }
        guard let ratio = preset.ratio(original: manifest.pixelSize) else { return }
        let bounds = CGRect(origin: .zero, size: manifest.pixelSize)
        let pixel = StudioCropGeometry.pixelRect(workingCrop, in: bounds.size)
        let resized = CropRectEditor.resized(
            pixel,
            handle: .bottomTrailing,
            translation: .zero,
            aspect: ratio,
            bounds: bounds
        )
        workingCrop = StudioCropGeometry.normalized(resized, in: bounds.size)
    }

    func updateWorkingCrop(handle: CropHandle, translation: CGSize, inFitted fitted: CGRect) {
        guard isCropping, fitted.width > 0, fitted.height > 0 else { return }
        let view = StudioCropGeometry.viewRect(forNormalized: workingCrop, inFitted: fitted)
        let ratio = cropAspect.ratio(original: manifest.pixelSize)
        let next = CropRectEditor.resized(
            view,
            handle: handle,
            translation: translation,
            aspect: handle == .body ? nil : ratio,
            bounds: fitted
        )
        workingCrop = StudioCropGeometry.normalized(next, inFitted: fitted)
    }
}

/// Mapping between the fitted preview image and a normalised crop.
enum StudioCropGeometry {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    static func fittedImageRect(image: CGSize, in container: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func viewRect(forNormalized crop: CGRect, inFitted fitted: CGRect) -> CGRect {
        CGRect(
            x: fitted.minX + crop.minX * fitted.width,
            y: fitted.minY + crop.minY * fitted.height,
            width: crop.width * fitted.width,
            height: crop.height * fitted.height
        )
    }

    static func normalized(_ view: CGRect, inFitted fitted: CGRect) -> CGRect {
        guard fitted.width > 0, fitted.height > 0 else { return StudioCropGeometry.unit }
        return clamped(CGRect(
            x: (view.minX - fitted.minX) / fitted.width,
            y: (view.minY - fitted.minY) / fitted.height,
            width: view.width / fitted.width,
            height: view.height / fitted.height
        ))
    }

    static func pixelRect(_ crop: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: crop.minX * size.width,
            y: crop.minY * size.height,
            width: crop.width * size.width,
            height: crop.height * size.height
        )
    }

    static func normalized(_ pixel: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return StudioCropGeometry.unit }
        return clamped(CGRect(
            x: pixel.minX / size.width,
            y: pixel.minY / size.height,
            width: pixel.width / size.width,
            height: pixel.height / size.height
        ))
    }

    static func isFullFrame(_ crop: CGRect) -> Bool {
        abs(crop.minX) < 0.001
            && abs(crop.minY) < 0.001
            && abs(crop.width - 1) < 0.001
            && abs(crop.height - 1) < 0.001
    }

    static func clamped(_ crop: CGRect) -> CGRect {
        let x = min(max(crop.minX, 0), 0.95)
        let y = min(max(crop.minY, 0), 0.95)
        let width = min(max(crop.width, 0.05), 1 - x)
        let height = min(max(crop.height, 0.05), 1 - y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
