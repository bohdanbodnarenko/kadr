import Foundation
import Testing
@testable import Kadr

/// Where a Kadr run from the disk image is moved to (docs/17 T-SH-2).
@Suite("Move to Applications")
struct MoveToApplicationsTests {
    @Test("The system folder when it can be written, the user's own when not", arguments: [
        (true, "/Applications"),
        (false, "/Users/tester/Applications")
    ])
    func destination(writable: Bool, expected: String) {
        let folder = MoveToApplications.destinationFolder(systemApplicationsWritable: writable, home: "/Users/tester")
        #expect(folder.path == expected)
    }

    @Test("A build run from Xcode or a test host is never offered the move")
    func hostIsNotOffered() {
        #expect(!RunLocation.classify(bundlePath: Bundle.main.bundlePath).shouldOfferMove)
    }

    @Test("Only the same or an older build in Applications is replaced", arguments: [
        ("100", "101", true),
        ("101", "101", true),
        ("102", "101", false),
        ("1.10", "1.9", false),
        ("1.9", "1.10", true)
    ] as [(String?, String?, Bool)] + [(nil, "5", true), ("5", nil, true)])
    func replacement(existing: String?, incoming: String?, replaces: Bool) {
        #expect(MoveToApplications.shouldReplace(existing: existing, with: incoming) == replaces)
    }
}
