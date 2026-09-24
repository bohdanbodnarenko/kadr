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
}
