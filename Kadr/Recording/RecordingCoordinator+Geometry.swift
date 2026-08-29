import AppKit
import Foundation
import OverlayKit
import RecordingCore
import Shared

/// Turning a screen click into a pixel of the recording (docs/03 §1.8).
///
/// Split from the coordinator because it is pure geometry with no state at all, while the
/// coordinator is nothing but state — and because the coordinator was over its length
/// budget once the studio clock arrived.
@MainActor
extension RecordingCoordinator {
    /// Maps a screen click into the recorded frame's own pixels.
    ///
    /// Clicks arrive in AppKit's screen space; the frame is in the recorded area's pixels
    /// with a top-left origin. Getting this wrong puts the halo somewhere else entirely,
    /// which is why it goes through `Shared.Geometry` rather than ad-hoc arithmetic.
    static func pointConverter(
        for target: RecordingTarget
    ) -> @Sendable (CGPoint) -> CGPoint? {
        let space = GlobalCoordinateSpace.current
        let screens = NSScreen.screens.compactMap(ScreenDescriptor.init)

        switch target {
        case let .display(displayID):
            guard let screen = screens.first(where: { $0.displayID == displayID }) else {
                return { _ in nil }
            }
            let frame = screen.frame.cgRect
            let scale = screen.backingScaleFactor
            return { point in
                guard frame.contains(point) else { return nil }
                return CGPoint(
                    x: (point.x - frame.minX) * scale,
                    y: (frame.maxY - point.y) * scale
                )
            }

        case let .region(rect, displayID):
            guard let screen = screens.first(where: { $0.displayID == displayID }) else {
                return { _ in nil }
            }
            let scale = screen.backingScaleFactor
            let regionInScreenSpace = rect.inScreenSpace(space)
            return { point in
                guard regionInScreenSpace.cgRect.contains(point) else { return nil }
                return CGPoint(
                    x: (point.x - regionInScreenSpace.minX) * scale,
                    y: (regionInScreenSpace.maxY - point.y) * scale
                )
            }

        case .window:
            // A window moves while being recorded, so a click's position within the frame
            // cannot be derived from where it landed on screen. Halos are left off rather
            // than drawn in the wrong place.
            return { _ in nil }
        }
    }
}
