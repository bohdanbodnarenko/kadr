import AVFoundation
import Foundation
import Testing
@testable import Kadr

/// docs/18 REC P3: recording alerts say what happened in plain words.
@Suite("Recording failure messages")
struct RecordingFailureMessageTests {
    @Test("Known framework errors get a plain message", arguments: [
        (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue, "disk is full"),
        (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError, "disk is full"),
        (AVFoundationErrorDomain, AVError.Code.deviceWasDisconnected.rawValue, "disconnected"),
        (NSCocoaErrorDomain, NSFileWriteNoPermissionError, "not allowed to write")
    ])
    func plain(domain: String, code: Int, fragment: String) {
        let error = NSError(domain: domain, code: code)
        #expect(RecordingFailureNotice.message(for: error).contains(fragment))
    }

    @Test("An underlying framework error is found too")
    func underlying() {
        let inner = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue)
        let outer = NSError(domain: "Kadr", code: 1, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(RecordingFailureNotice.message(for: outer).contains("disk is full"))
    }

    @Test("Anything else keeps its own description")
    func passthrough() {
        let error = NSError(domain: "Elsewhere", code: 7, userInfo: [NSLocalizedDescriptionKey: "Something specific."])
        #expect(RecordingFailureNotice.message(for: error) == "Something specific.")
    }
}
