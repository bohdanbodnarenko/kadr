import Foundation
import Testing
@testable import CaptureCore

/// docs/18 §4.2 P3: frame folders a crashed scrolling capture left are swept at launch.
@Suite("Scrolling frame sweep")
struct ScrollFrameSweepTests {
    @Test("Only Kadr's scroll frame folders are removed")
    func sweepsOnlyFrameFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrollFrameSweepTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent("\(ScrollCaptureSession.frameFolderPrefix)\(UUID().uuidString)")
        let unrelated = root.appendingPathComponent("Other-\(UUID().uuidString)")
        for folder in [orphan, unrelated] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        #expect(ScrollCaptureSession.sweepOrphanedFrames(in: root) == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
