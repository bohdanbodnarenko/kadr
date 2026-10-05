import Foundation
import ScreenCaptureKit
import Testing
@testable import CaptureCore

private func scError(_ code: SCStreamError.Code) -> NSError {
    NSError(domain: SCStreamErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "test"])
}

@Suite("ScreenCaptureKit error mapping")
struct CaptureErrorMappingTests {
    @Test("A declined capture is permission loss — this is how macOS 15 reports a lapsed grant")
    func userDeclined() {
        let error = CaptureError.mapping(scError(.userDeclined))
        #expect(error == .permissionDenied)
        #expect(error.indicatesPermissionLoss)
    }

    @Test("Missing entitlements also means the user must act")
    func missingEntitlements() {
        let error = CaptureError.mapping(scError(.missingEntitlements))
        #expect(error == .missingEntitlements)
        #expect(error.indicatesPermissionLoss)
    }

    @Test("Empty source lists are not a permission problem", arguments: [
        SCStreamError.Code.noCaptureSource,
        SCStreamError.Code.noDisplayList,
        SCStreamError.Code.noWindowList
    ])
    func noSource(code: SCStreamError.Code) {
        let error = CaptureError.mapping(scError(code))
        #expect(error == .noCaptureSource)
        #expect(error.indicatesPermissionLoss == false)
    }

    @Test("Unrecognised SCK codes keep their code and message")
    func unknownSCKCode() {
        let error = CaptureError.mapping(scError(.internalError))
        #expect(error == .captureFailed(code: SCStreamError.Code.internalError.rawValue, description: "test"))
        #expect(error.indicatesPermissionLoss == false)
    }

    @Test("Errors from other domains are not mistaken for permission loss")
    func foreignDomain() {
        // A window closing mid-capture must never tell the user their grant was revoked.
        let error = CaptureError.mapping(NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil))
        #expect(error.indicatesPermissionLoss == false)
        if case let .captureFailed(code, _) = error {
            #expect(code == 4)
        } else {
            Issue.record("expected .captureFailed, got \(error)")
        }
    }

    @Test("Mapping a CaptureError is the identity")
    func alreadyMapped() {
        #expect(CaptureError.mapping(CaptureError.emptyRegion) == .emptyRegion)
    }

    @Test("Every case has a message the UI can show")
    func allCasesDescribed() {
        let cases: [CaptureError] = [
            .permissionDenied, .missingEntitlements, .noCaptureSource,
            .displayNotFound(1), .windowNotFound(2), .regionOutsideDisplay,
            .emptyRegion, .captureFailed(code: -1, description: "boom")
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    /// docs/18 CAP-11: identifiers belong in the log, never in a banner.
    @Test("Messages carry no internal identifiers", arguments: [
        (CaptureError.displayNotFound(69_734_272), "69734272"),
        (.windowNotFound(4242), "4242"),
        (.captureFailed(code: -3801, description: "SCStreamErrorDomain boom"), "-3801")
    ])
    func noIdentifiersInMessages(error: CaptureError, identifier: String) {
        #expect(error.errorDescription?.contains(identifier) == false)
        #expect(error.logDescription.contains(identifier))
    }
}
