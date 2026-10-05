import AnnotationModel
import SwiftUI

/// Handles and a dimmed exterior over the studio preview while cropping.
struct StudioCropOverlay: View {
    let model: StudioDocumentModel
    let fitted: CGRect

    @State private var drag: (handle: CropHandle, origin: CGRect)?

    private let hitSize: CGFloat = 20

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
                cropHandle(handle, crop: crop)
            }
        }
        .contentShape(Rectangle())
        // The keyboard can crop too (docs/14 UX-33): the arrows move the frame a point,
        // ten with ⇧, and ⌥ resizes from the bottom-right corner instead.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            nudge(press)
        }
    }

    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        let delta: CGSize = switch press.key {
        case .leftArrow: CGSize(width: -step, height: 0)
        case .rightArrow: CGSize(width: step, height: 0)
        case .upArrow: CGSize(width: 0, height: -step)
        case .downArrow: CGSize(width: 0, height: step)
        default: .zero
        }
        guard delta != .zero else { return .ignored }
        let handle: CropHandle = press.modifiers.contains(.option) ? .bottomTrailing : .body
        model.updateWorkingCrop(handle: handle, translation: delta, inFitted: fitted)
        return .handled
    }

    /// One VoiceOver adjust step for a handle: two percent of the preview, outward on
    /// increment and inward on decrement.
    private func adjust(_ handle: CropHandle, _ direction: AccessibilityAdjustmentDirection) {
        let sign: CGFloat = direction == .increment ? 1 : -1
        let outward = handle.outward
        let delta = CGSize(
            width: outward.dx * sign * fitted.width * 0.02,
            height: outward.dy * sign * fitted.height * 0.02
        )
        model.updateWorkingCrop(handle: handle, translation: delta, inFitted: fitted)
    }

    private func cropHandle(_ handle: CropHandle, crop: CGRect) -> some View {
        let point = handle.point(in: crop)
        return Circle()
            .fill(.white)
            .frame(width: 10, height: 10)
            .shadow(radius: 1)
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .position(x: point.x, y: point.y)
            .gesture(dragGesture(handle: handle))
            .onHover { hovering in
                if hovering {
                    Self.cursor(for: handle).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(handle.accessibilityTitle)
            .accessibilityHint(Text("Adjust to grow or shrink the crop", bundle: .module))
            .accessibilityAdjustableAction { direction in adjust(handle, direction) }
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

private extension CropHandle {
    /// The direction this handle moves to make the crop bigger.
    var outward: CGVector {
        switch self {
        case .topLeading: CGVector(dx: -1, dy: -1)
        case .top: CGVector(dx: 0, dy: -1)
        case .topTrailing: CGVector(dx: 1, dy: -1)
        case .leading: CGVector(dx: -1, dy: 0)
        case .trailing: CGVector(dx: 1, dy: 0)
        case .bottomLeading: CGVector(dx: -1, dy: 1)
        case .bottom: CGVector(dx: 0, dy: 1)
        case .bottomTrailing: CGVector(dx: 1, dy: 1)
        case .body: CGVector(dx: 0, dy: 0)
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .topLeading: "Crop top left"
        case .top: "Crop top edge"
        case .topTrailing: "Crop top right"
        case .leading: "Crop left edge"
        case .body: "Move crop"
        case .trailing: "Crop right edge"
        case .bottomLeading: "Crop bottom left"
        case .bottom: "Crop bottom edge"
        case .bottomTrailing: "Crop bottom right"
        }
    }
}

extension StudioCropOverlay {
    /// The resize cursor that matches the handle (docs/17 T-STU-12): every handle used to
    /// show left-right, including the top, the bottom and the corners.
    static func cursor(for handle: CropHandle) -> NSCursor {
        if #available(macOS 15, *) {
            guard let position = framePositions[handle] else { return .openHand }
            return .frameResize(position: position, directions: .all)
        }
        return legacyCursors[handle] ?? .crosshair
    }

    @available(macOS 15, *)
    private static let framePositions: [CropHandle: NSCursor.FrameResizePosition] = [
        .topLeading: .topLeft, .top: .top, .topTrailing: .topRight,
        .leading: .left, .trailing: .right,
        .bottomLeading: .bottomLeft, .bottom: .bottom, .bottomTrailing: .bottomRight
    ]

    /// macOS 14 has only the two straight resize cursors.
    private static let legacyCursors: [CropHandle: NSCursor] = [
        .top: .resizeUpDown, .bottom: .resizeUpDown,
        .leading: .resizeLeftRight, .trailing: .resizeLeftRight,
        .body: .openHand
    ]
}
