import Testing
@testable import CaptureCore

/// docs/18 CAP-5: the macOS 15.2 direct path is used only when it can honour the request.
@Suite("Direct rect capture")
struct DirectRectCaptureTests {
    @Test("Cursor or HDR sends a capture to the filter path", arguments: [
        (false, false, true),
        (true, false, false),
        (false, true, false),
        (true, true, false)
    ])
    func honours(includesCursor: Bool, wantsHDR: Bool, direct: Bool) {
        #expect(CaptureEngine.directRectCaptureHonours(includesCursor: includesCursor, wantsHDR: wantsHDR) == direct)
    }
}
