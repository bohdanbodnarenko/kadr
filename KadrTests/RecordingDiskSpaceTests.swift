import Foundation
import Testing
@testable import Kadr

/// The free-space check before a take (docs/17 T-REC-10).
@Suite("Recording disk space")
struct RecordingDiskSpaceTests {
    private static let inProgress = URL(fileURLWithPath: "/in-progress")
    private static let saves = URL(fileURLWithPath: "/Volumes/External/Saves")

    @Test(
        "Refuses only a volume below the floor",
        arguments: [
            (Int64(10_000_000_000), Int64(10_000_000_000), nil as String?),
            (Int64(100_000_000), Int64(10_000_000_000), "Macintosh HD"),
            (Int64(10_000_000_000), Int64(100_000_000), "External"),
            (RecordingDiskSpace.minimumBytes, RecordingDiskSpace.minimumBytes, nil)
        ]
    )
    func floor(internalBytes: Int64, externalBytes: Int64, short: String?) {
        let shortage = RecordingDiskSpace.shortage(in: [Self.inProgress, Self.saves]) { url in
            url == Self.inProgress ? ("Macintosh HD", internalBytes) : ("External", externalBytes)
        }
        #expect(shortage?.volumeName == short)
    }

    @Test("A volume whose capacity cannot be read does not block recording")
    func unknownCapacity() {
        #expect(RecordingDiskSpace.shortage(in: [Self.inProgress]) { _ in nil } == nil)
    }

    @Test("The real temporary folder reports a capacity")
    func realVolume() {
        #expect(RecordingDiskSpace.availableCapacity(of: FileManager.default.temporaryDirectory) != nil)
    }

    /// docs/18 REC-8: the running take checks every ten recorded seconds, once each.
    @Test("A running take checks the disk every ten seconds, once", arguments: [
        (0, nil as Int?, false),
        (5, nil, false),
        (10, nil, true),
        (10, 10, false),
        (20, 10, true)
    ])
    func checkCadence(second: Int, lastChecked: Int?, due: Bool) {
        #expect(RecordingDiskSpace.isCheckDue(atWholeSecond: second, lastChecked: lastChecked) == due)
    }

    @Test("A take stops below the margin", arguments: [
        (Int64(100_000_000), true),
        (749_999_999, true),
        (750_000_000, false),
        (10_000_000_000, false)
    ])
    func stopMargin(bytes: Int64, stops: Bool) {
        #expect(RecordingDiskSpace.mustStop(availableBytes: bytes) == stops)
    }
}
