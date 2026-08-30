import CaptureCore
import CoreGraphics
import OverlayKit
import RecordingCore

/// Pushes the live exclusion list into a capture engine (docs/10 R3.2).
///
/// OverlayKit cannot import CaptureCore, so the registry cannot talk to ScreenCaptureKit
/// itself. The agent is the seam: read the IDs here, set them on the engine, then freeze
/// or record. Every overlay that is on screen is already on the registry.
@MainActor
enum CaptureExclusionPush {
    static var ids: Set<CGWindowID> {
        CaptureExclusionRegistry.shared.excludedWindowIDs
    }

    static func into(_ engine: CaptureEngine) async {
        await engine.setExcludedWindowIDs(ids)
    }

    static func into(_ engine: RecordingEngine) async {
        await engine.setExcludedWindowIDs(ids)
    }

    static func into(_ session: ScrollCaptureSession) async {
        await session.setExcludedWindowIDs(ids)
    }
}
