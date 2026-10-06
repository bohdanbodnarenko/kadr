import AppKit
import CoreGraphics

/// Which pointer the selection screen shows, and where (docs/18 CAP P3).
///
/// A crosshair everywhere hid the two other things the screen can do: click a window in
/// window mode, and grab a handle or the selection itself in confirm mode. Worked out as a
/// plain value so the rules can be tested without a window.
struct SelectionCursorPlan: Equatable {
    enum Shape: Equatable {
        case crosshair
        case pointingHand
        case openHand
        case resize(SelectionHandleLayerGroup.Corner)
    }

    struct Region: Equatable {
        let rect: CGRect
        let shape: Shape
    }

    /// Later regions win where they overlap, as `addCursorRect` resolves them.
    let regions: [Region]

    init(
        bounds: CGRect,
        isWindowMode: Bool,
        isEyedropper: Bool,
        adjustableSelection: CGRect?,
        handleRadius: CGFloat
    ) {
        if isEyedropper {
            regions = [Region(rect: bounds, shape: .crosshair)]
            return
        }
        if isWindowMode {
            regions = [Region(rect: bounds, shape: .pointingHand)]
            return
        }
        var regions = [Region(rect: bounds, shape: .crosshair)]
        if let selection = adjustableSelection {
            regions.append(Region(rect: selection, shape: .openHand))
            for corner in SelectionHandleLayerGroup.Corner.allCases {
                let point = corner.point(in: selection)
                let hit = CGRect(
                    x: point.x - handleRadius,
                    y: point.y - handleRadius,
                    width: handleRadius * 2,
                    height: handleRadius * 2
                )
                regions.append(Region(rect: hit, shape: .resize(corner)))
            }
        }
        self.regions = regions
    }
}

extension SelectionCursorPlan.Shape {
    @MainActor var cursor: NSCursor {
        switch self {
        case .crosshair: .crosshair
        case .pointingHand: .pointingHand
        case .openHand: .openHand
        case let .resize(corner):
            if #available(macOS 15.0, *) {
                NSCursor.frameResize(position: corner.framePosition, directions: .all)
            } else {
                .crosshair
            }
        }
    }
}

@available(macOS 15.0, *)
private extension SelectionHandleLayerGroup.Corner {
    /// The view is flipped (top-left origin), so `topLeft` is the top-left on screen.
    var framePosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        }
    }
}

extension SelectionOverlayView {
    var cursorPlan: SelectionCursorPlan {
        SelectionCursorPlan(
            bounds: bounds,
            isWindowMode: mode == .window,
            isEyedropper: isEyedropperMode,
            adjustableSelection: confirmsSelection && interaction.phase == .selected ? interaction.rect : nil,
            handleRadius: SelectionHandleLayerGroup.hitRadius
        )
    }
}
