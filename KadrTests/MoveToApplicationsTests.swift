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
}
