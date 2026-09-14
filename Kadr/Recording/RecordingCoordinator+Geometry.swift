import AppKit
import CaptureCore
import Foundation
import os
import OverlayKit
import RecordingCore
import SelectionUI
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
    /// The notch strip at the top of the recorded display, in recorded pixels (docs/08 §2).
    ///
    /// `safeAreaInsets.top` is the display's own account of the area beside the notch, so
    /// this asks the one thing that knows rather than assuming a menu-bar height — which is
    /// wrong on precisely the Macs that have a notch, since theirs is taller.
    ///
    /// Zero for a region recording: the strip is only meaningful when the recording starts
    /// at the top of the display, and a region the user drew somewhere else has no notch in
    /// it to remove.
    static func topInset(for target: RecordingTarget) -> CGFloat {
        guard case let .display(displayID) = target else { return 0 }
        guard let screen = NSScreen.screens.first(where: {
            ScreenDescriptor($0)?.displayID == displayID
        }) else {
            return 0
        }
        return screen.safeAreaInsets.top * screen.backingScaleFactor
    }

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

    /// The dim around a region, or around a window once we know where it is.
    func presentHighlight(for target: RecordingTarget) {
        switch target {
        case .region:
            areaHighlight.show(for: target)
        case .display:
            areaHighlight.hide()
        case .window:
            if let hole = windowHighlightHole, let id = windowHighlightDisplayID {
                areaHighlight.showWindow(hole: hole, displayID: id)
            } else {
                areaHighlight.hide()
            }
        }
    }

    /// Remembers the picked window's frame so the dim is up before the first captured frame.
    func beginWindowHighlight(from selection: WindowSelection) {
        windowHighlightHole = selection.display.globalRect(for: DisplayRect(cgRect: selection.window.frame))
        windowHighlightDisplayID = selection.display.displayID
    }

    func followWindowHighlight(contentRect: CGRect) {
        let hole = DisplayRect(cgRect: contentRect)
        windowHighlightHole = hole
        let displayID = Self.displayID(containing: hole) ?? windowHighlightDisplayID ?? CGMainDisplayID()
        windowHighlightDisplayID = displayID
        areaHighlight.showWindow(hole: hole, displayID: displayID)
    }

    static func displayID(containing hole: DisplayRect) -> CGDirectDisplayID? {
        NSScreen.screens.compactMap(ScreenDescriptor.init).first { descriptor in
            DisplayRect(cgRect: CGDisplayBounds(descriptor.displayID)).intersects(hole)
        }?.displayID
    }

    /// Records a named rectangle with no overlay (docs/03 §8.4 `x,y,w,h` and `display=`).
    func beginRegionRecording(_ screenRect: ScreenRect) {
        guard !isRecording else { return }
        let global = screenRect.inDisplaySpace(.current)
        guard let displayID = DisplayLookup.display(containing: global) else {
            logger.error("The requested recording region is not on any display")
            return
        }
        startAfterCountdown(target: .region(global, display: displayID))
    }

    /// Picks a region with the selection overlay, then records it.
    func beginRegionRecording() {
        guard !isRecording else { return }
        guard recovery.allowCapture(permissions: permissions, includePicker: false) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                await CaptureExclusionPush.into(captureEngine)
                let freezes = try await captureEngine.freezeAllDisplays()
                permissions.noteCaptureSuccess()
                overlay.present(
                    freezes: freezes.map { FrozenDisplay(geometry: $0.geometry, image: $0.image) }
                ) { [weak self] outcome in
                    guard case let .region(result) = outcome else {
                        self?.wantsGIFExport = false
                        return
                    }
                    self?.startAfterCountdown(
                        target: .region(result.rect, display: result.display.displayID)
                    )
                }
            } catch {
                wantsGIFExport = false
                permissions.noteCaptureFailure(error)
                logger.error("Could not freeze for recording: \(error.localizedDescription, privacy: .public)")
                presentPermissionRecoveryIfNeeded(error)
            }
        }
    }

    /// Dedicated GIF capture: same region overlay, then GIF-encode on stop (CleanShot §13.6).
    func beginGIFRecording() {
        guard !isRecording else { return }
        wantsGIFExport = true
        beginRegionRecording()
    }
}
