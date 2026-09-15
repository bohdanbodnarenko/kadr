import Foundation
import Testing
@testable import Shared

/// The editor telling the agent it trashed a capture (docs/03 §3).
@Suite("Capture deletion notice")
struct CaptureDeletionNoticeTests {
    @Test("Paths survive the trip", arguments: [
        ("/Users/me/Desktop/Shot.png", "/Users/me/.Trash/Shot.png"),
        ("/Users/me/Desktop/Kadr 2026-09-15 at 10.00.png", "/Users/me/.Trash/Kadr 2026-09-15 at 10.00 12-01-33.png"),
        ("/Volumes/Work/\"quoted\" ünïcode.png", "/Volumes/Work/.Trashes/501/\"quoted\" ünïcode.png")
    ])
    func roundTrip(original: String, trashed: String) throws {
        let paths = CaptureDeletionNotice.Paths(
            original: URL(fileURLWithPath: original),
            trashed: URL(fileURLWithPath: trashed)
        )
        let encoded = try #require(CaptureDeletionNotice.encode(paths))
        #expect(CaptureDeletionNotice.decode(encoded) == paths)
    }

    @Test("Anything that is not a well-formed notice is rejected", arguments: [
        nil,
        "",
        "not json",
        #"["/only/one"]"#,
        #"["relative/path.png", "/Users/me/.Trash/x.png"]"#,
        #"["/a", "/b", "/c"]"#
    ] as [String?])
    func malformedIsRejected(object: String?) {
        #expect(CaptureDeletionNotice.decode(object) == nil)
    }

    @Test("A non-string object is rejected")
    func nonStringIsRejected() {
        #expect(CaptureDeletionNotice.decode(42) == nil)
    }

    @Test("Only a Trash counts as the Trash", arguments: [
        ("/Users/me/.Trash/x.png", true),
        ("/Volumes/Work/.Trashes/501/x.png", true),
        ("/Users/me/Desktop/x.png", false),
        ("/Users/me/.Trashy/x.png", false),
        ("/Users/me/Desktop/.Trash-notes/x.png", false)
    ])
    func trashDetection(path: String, isTrash: Bool) {
        #expect(CaptureDeletionNotice.isInTrash(URL(fileURLWithPath: path)) == isTrash)
    }
}
