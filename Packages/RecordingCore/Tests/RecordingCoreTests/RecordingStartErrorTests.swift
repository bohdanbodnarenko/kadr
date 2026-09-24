import CaptureCore
import Foundation
import ScreenCaptureKit
import Testing
@testable import RecordingCore

/// What a ScreenCaptureKit failure at start turns into (docs/17 T-REC-9).
///
/// A lapsed consent used to read "That screen or window is no longer available", so the
/// user was never offered the way back to System Settings.
@Suite("Recording start errors")
struct RecordingStartErrorTests {
    private static func streamError(_ code: SCStreamError.Code) -> NSError {
        NSError(domain: SCStreamErrorDomain, code: code.rawValue)
    }

    @Test(
        "Permission failures stay permission failures",
        arguments: [SCStreamError.Code.userDeclined, .missingEntitlements]
    )
    func permissionLoss(code: SCStreamError.Code) {
        let error = RecordingEngine.startError(Self.streamError(code)) { .writingFailed($0) }
        #expect(CaptureError.mapping(error).indicatesPermissionLoss)
    }

    @Test(
        "A vanished source is an unavailable target",
        arguments: [SCStreamError.Code.noCaptureSource, .noDisplayList, .noWindowList]
    )
    func vanishedSource(code: SCStreamError.Code) {
        let error = RecordingEngine.startError(Self.streamError(code)) { .writingFailed($0) }
        #expect(error as? RecordingError == .targetUnavailable)
    }

    @Test("Anything else falls back to the caller's own error")
    func otherFailures() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [
            NSLocalizedDescriptionKey: "No space left on device"
        ])
        let error = RecordingEngine.startError(underlying) { .writingFailed($0) }
        #expect(error as? RecordingError == .writingFailed("No space left on device"))
    }
}
