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

    struct Replacement: Sendable {
        let existing: String?
        let incoming: String?
        let replaces: Bool
    }

    @Test("Only the same or an older build in Applications is replaced", arguments: [
        Replacement(existing: "100", incoming: "101", replaces: true),
        Replacement(existing: "101", incoming: "101", replaces: true),
        Replacement(existing: "102", incoming: "101", replaces: false),
        Replacement(existing: "1.10", incoming: "1.9", replaces: false),
        Replacement(existing: "1.9", incoming: "1.10", replaces: true),
        Replacement(existing: nil, incoming: "5", replaces: true),
        Replacement(existing: "5", incoming: nil, replaces: true)
    ])
    func replacement(row: Replacement) {
        #expect(MoveToApplications.shouldReplace(existing: row.existing, with: row.incoming) == row.replaces)
    }
}
