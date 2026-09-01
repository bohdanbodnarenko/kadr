import AnnotationModel
import SwiftUI

/// Handles and a dimmed exterior over the studio preview while cropping.
struct StudioCropOverlay: View {
    let model: StudioDocumentModel
    let fitted: CGRect

    @State private var drag: (handle: CropHandle, origin: CGRect)?

    var body: some View {
        let crop = StudioCropGeometry.viewRect(forNormalized: model.workingCrop, inFitted: fitted)
        ZStack {
            dimmers(around: crop)
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
                .allowsHitTesting(false)
            Color.clear
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
                .contentShape(Rectangle())
                .gesture(dragGesture(handle: .body))
            ForEach(CropHandle.resizeHandles, id: \.self) { handle in
                let point = handle.point(in: crop)
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .shadow(radius: 1)
                    .position(x: point.x, y: point.y)
                    .gesture(dragGesture(handle: handle))
            }
        }
        .contentShape(Rectangle())
    }

    private func dimmers(around crop: CGRect) -> some View {
        let bounds = fitted
        return ZStack {
            dim(CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(crop.minY - bounds.minY, 0)))
            dim(CGRect(
                x: bounds.minX,
                y: crop.maxY,
                width: bounds.width,
                height: max(bounds.maxY - crop.maxY, 0)
            ))
            dim(CGRect(
                x: bounds.minX,
                y: crop.minY,
                width: max(crop.minX - bounds.minX, 0),
                height: crop.height
            ))
            dim(CGRect(
                x: crop.maxX,
                y: crop.minY,
                width: max(bounds.maxX - crop.maxX, 0),
                height: crop.height
            ))
        }
        .allowsHitTesting(false)
    }

    private func dim(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(.black.opacity(0.45))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func dragGesture(handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if drag == nil {
                    drag = (handle, model.workingCrop)
                }
                model.workingCrop = drag?.origin ?? model.workingCrop
                model.updateWorkingCrop(handle: handle, translation: value.translation, inFitted: fitted)
            }
            .onEnded { _ in
                drag = nil
            }
    }
}
