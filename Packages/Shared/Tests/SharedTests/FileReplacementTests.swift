import Foundation
import Testing
@testable import Shared

/// Replacing a file the user agreed to replace (docs/18 §4.3 P3).
@Suite("File replacement")
struct FileReplacementTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileReplacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Move and copy land the new bytes, with or without a file in the way", arguments: [
        (true, true), (true, false), (false, true), (false, false)
    ])
    func replaces(moving: Bool, destinationExists: Bool) throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("new.txt")
        let destination = folder.appendingPathComponent("target.txt")
        try "new".write(to: source, atomically: true, encoding: .utf8)
        if destinationExists {
            try "old".write(to: destination, atomically: true, encoding: .utf8)
        }

        let result = moving
            ? try FileReplacement.move(source, to: destination)
            : try FileReplacement.copy(source, to: destination)

        #expect(try contents(result) == "new")
        #expect(FileManager.default.fileExists(atPath: source.path) == !moving)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test("A failed move leaves the existing file alone")
    func failureKeepsOriginal() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("target.txt")
        try "old".write(to: destination, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try FileReplacement.move(folder.appendingPathComponent("missing.txt"), to: destination)
        }
        #expect(try contents(destination) == "old")
    }
}
