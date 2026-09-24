import CaptureCore
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Shared

/// Turning a recording target into something ScreenCaptureKit will capture (docs/03 §1.8).
///
/// Split from the engine's own file because choosing *what* to record and running the
/// capture change for different reasons: this one moves when Apple changes the filter API
/// or when Kadr gains a new kind of target, and the engine moves when the writing does.
extension RecordingEngine {
    func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.startError(error, otherwise: { _ in .targetUnavailable })
        }
    }

    /// What a ScreenCaptureKit failure during start means to the user (docs/17 T-REC-9).
    ///
    /// Every failure here used to read "That screen or window is no longer available",
    /// including the lapsed monthly consent on macOS 15+ — so the user was never offered
    /// the way back to System Settings. A declined grant comes out as
    /// `CaptureError.permissionDenied`, which the coordinator's recovery already knows.
    static func startError(
        _ error: any Error,
        otherwise: (String) -> RecordingError
    ) -> any Error {
        let mapped = CaptureError.mapping(error)
        if mapped.indicatesPermissionLoss {
            return mapped
        }
        if mapped == .noCaptureSource {
            return RecordingError.targetUnavailable
        }
        return otherwise(error.localizedDescription)
    }

    /// What one target resolves to: what to capture, how big, and which part of it.
    struct CaptureSetup {
        let filter: SCContentFilter
        let pixelSize: PixelSize
        /// Display-local points for a region; `nil` captures the whole filter.
        let sourceRect: CGRect?
    }

    func makeFilter(
        for target: RecordingTarget,
        in content: SCShareableContent
    ) throws -> CaptureSetup {
        switch target {
        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.targetUnavailable
            }
            let filter = filterExcludingOwnWindows(display: display, in: content)
            return CaptureSetup(filter: filter, pixelSize: pixelSize(of: filter), sourceRect: nil)

        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.targetUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return CaptureSetup(filter: filter, pixelSize: pixelSize(of: filter), sourceRect: nil)

        case let .region(rect, displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.targetUnavailable
            }
            let filter = filterExcludingOwnWindows(display: display, in: content)
            let scale = CGFloat(filter.pointPixelScale)
            let geometry = DisplayGeometry(
                displayID: displayID,
                frame: DisplayRect(cgRect: display.frame),
                scale: DisplayScale(scale)
            )
            guard let clamped = geometry.clamped(rect) else { throw RecordingError.targetUnavailable }
            let local = geometry.localRect(for: clamped)
            let pixels = geometry.pixels(for: local)
            return CaptureSetup(
                filter: filter,
                // Even dimensions: hardware encoders reject odd ones.
                pixelSize: PixelSize(width: even(pixels.width), height: even(pixels.height)),
                sourceRect: local.cgRect
            )
        }
    }

    func filterExcludingOwnWindows(display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        // Per-window, never the whole app: the HUD and stop button register themselves,
        // Settings does not (docs/10 R3.2).
        let windows = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: windows)
    }

    func pixelSize(of filter: SCContentFilter) -> PixelSize {
        let scale = CGFloat(filter.pointPixelScale)
        pointPixelScale = scale
        return PixelSize(
            width: even(Int((filter.contentRect.width * scale).rounded())),
            height: even(Int((filter.contentRect.height * scale).rounded()))
        )
    }

    /// Hardware encoders require even dimensions.
    func even(_ value: Int) -> Int {
        value % 2 == 0 ? value : value - 1
    }
}
