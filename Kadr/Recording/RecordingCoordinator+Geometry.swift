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
    /// Typed on both ends (docs/11 S0.1). It used to take a bare `CGPoint` and assume it
    /// was screen space, which is true of `NSEvent.mouseLocation` and false of a
    /// `CGEvent`'s `location` — the two are vertical mirrors of each other and both are a
    /// `CGPoint`, so the event tap fed display-space points into a screen-space flip and
    /// every recorded sample came out mirrored. Nothing could catch it: the types agreed,
    /// the arithmetic was right, and the two errors cancelled into a plausible number.
    ///
    /// A `ScreenPoint` in and a `PixelPoint` out means the tap has to name what it has
    /// before it can call this, and naming it wrong no longer compiles.
    static func pointConverter(
        for target: RecordingTarget
    ) -> @Sendable (ScreenPoint) -> PixelPoint? {
        let space = GlobalCoordinateSpace.current
        let screens = NSScreen.screens.compactMap(ScreenDescriptor.init)

        switch target {
        case let .display(displayID):
            guard let screen = screens.first(where: { $0.displayID == displayID }) else {
                return { _ in nil }
            }
            let frame = ScreenRect(cgRect: screen.frame.cgRect)
            let scale = DisplayScale(screen.backingScaleFactor)
            return { point in frame.pixelPoint(for: point, scale: scale) }

        case let .region(rect, displayID):
            guard let screen = screens.first(where: { $0.displayID == displayID }) else {
                return { _ in nil }
            }
            let scale = DisplayScale(screen.backingScaleFactor)
            let region = rect.inScreenSpace(space)
            return { point in region.pixelPoint(for: point, scale: scale) }

        case .window:
            // A window moves while being recorded, so a click's position within the frame
            // cannot be derived from where it landed on screen. Halos are left off rather
            // than drawn in the wrong place; the studio path uses `MovingWindowConverter`.
            return { _ in nil }
        }
    }

    /// How many pixels the recorded display puts in a point (docs/11 S0.5).
    ///
    /// Everything the sidecar records is already in the recording's own pixels — the
    /// pointer path, the click positions — with one exception: the cursor artwork, because
    /// `NSCursor` measures its size and its hotspot in points. This is the number that
    /// reconciles them, and it has to be captured now: by the time anybody opens the editor
    /// the display that was recorded may not even be attached.
    static func pointPixelScale(for target: RecordingTarget) -> CGFloat {
        let screens = NSScreen.screens.compactMap(ScreenDescriptor.init)
        let displayID: CGDirectDisplayID? = switch target {
        case let .display(id): id
        case let .region(_, id): id
        // A window recording is captured at the scale of whatever display it is on, and
        // SCK reports that per frame; the main display is the best answer available here
        // and is the right one whenever the window has not been dragged to a second screen
        // with a different density.
        case .window: CGMainDisplayID()
        }
        guard let displayID,
              let screen = screens.first(where: { $0.displayID == displayID })
        else {
            return NSScreen.main?.backingScaleFactor ?? 2
        }
        return screen.backingScaleFactor
    }
}
