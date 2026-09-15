import Foundation
import Testing
@testable import RecordingCore

@Suite("Interrupted recording folders")
struct InterruptedRecordingStoreTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-interrupted-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Only Kadr recording folders are discovered")
    func discoversPrefixedDirectories() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let recording = root.appendingPathComponent(
            "\(InterruptedRecordingStore.directoryPrefix)ABCD",
            isDirectory: true
        )
        let other = root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: root.appendingPathComponent("Kadr-Recording-file"))

        let found = InterruptedRecordingStore.directories(in: root)
        #expect(found.map(\.lastPathComponent) == [recording.lastPathComponent])
    }

    @Test("Segments are returned in recording order")
    func ordersSegmentFiles() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("a".utf8).write(to: root.appendingPathComponent("segment-10.mp4"))
        try Data("b".utf8).write(to: root.appendingPathComponent("segment-2.mp4"))
        try Data("c".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let names = InterruptedRecordingStore.segmentFiles(in: root).map(\.lastPathComponent)
        #expect(names == ["segment-2.mp4", "segment-10.mp4"])
    }

    @Test("In-progress recordings live under Application Support")
    func inProgressRootIsDurable() {
        let root = InterruptedRecordingStore.inProgressRoot()
        #expect(root.path.contains("Application Support/Kadr/InProgress"))
    }

    @Test("Discovery scans every supplied root")
    func scansMultipleRoots() throws {
        let first = scratch()
        let second = scratch()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let recording = second.appendingPathComponent(
            "\(InterruptedRecordingStore.directoryPrefix)XYZ",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        let found = InterruptedRecordingStore.directories(in: [first, second])
        #expect(found.map(\.lastPathComponent) == [recording.lastPathComponent])
    }
}
