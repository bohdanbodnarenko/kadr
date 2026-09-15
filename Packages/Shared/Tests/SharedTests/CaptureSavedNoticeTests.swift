import Foundation
import Testing
@testable import Shared

@Suite("Capture saved notice")
struct CaptureSavedNoticeTests {
    @Test("Paths survive the trip", arguments: [
        ("/Users/me/Desktop/Shot.png", "/Users/me/Desktop/Shot annotated.png", nil as String?),
        ("/Users/me/Desktop/Shot.png", "/Users/me/Desktop/Shot.png", "abc123")
    ])
    func roundTrip(original: String, saved: String, hash: String?) throws {
        let paths = CaptureSavedNotice.Paths(
            original: URL(fileURLWithPath: original),
            saved: URL(fileURLWithPath: saved),
            previousHash: hash
        )
        let encoded = try #require(CaptureSavedNotice.encode(paths))
        #expect(CaptureSavedNotice.decode(encoded) == paths)
    }

    @Test("Malformed payloads are rejected")
    func malformedIsRejected() {
        #expect(CaptureSavedNotice.decode("not json") == nil)
        #expect(CaptureSavedNotice.decode(#"["/only/one"]"#) == nil)
        #expect(CaptureSavedNotice.decode(#"["relative.png", "/tmp/x.png"]"#) == nil)
    }

    @Test("Validation requires both files and a sibling or save-folder path")
    func validation() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-saved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = folder.appendingPathComponent("Shot.png")
        let saved = folder.appendingPathComponent("Shot annotated.png")
        try Data("a".utf8).write(to: original)
        try Data("b".utf8).write(to: saved)

        let sibling = CaptureSavedNotice.Paths(original: original, saved: saved)
        #expect(sibling.isValid())

        let elsewhere = folder.deletingLastPathComponent().appendingPathComponent("other.png")
        try Data("c".utf8).write(to: elsewhere)
        let invalid = CaptureSavedNotice.Paths(original: original, saved: elsewhere)
        #expect(!invalid.isValid())

        let saveFolder = folder.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let inSave = saveFolder.appendingPathComponent("Shot.png")
        try Data("d".utf8).write(to: inSave)
        let relocated = CaptureSavedNotice.Paths(original: original, saved: inSave)
        #expect(relocated.isValid(saveFolder: saveFolder))
    }
}
