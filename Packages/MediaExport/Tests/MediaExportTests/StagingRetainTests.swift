import Foundation
@testable import MediaExport
import Testing

/// A staged file dropped into a file-URL-only app is kept from the sweep (docs/18 OUT-2).
@Suite("Staging retain")
struct StagingRetainTests {
    private func makeStaging() throws -> StagingArea {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagingRetainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StagingArea(directory: directory)
    }

    private func stagedFile(in staging: StagingArea, name: String, age: TimeInterval) throws -> URL {
        let url = staging.directory.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
        return url
    }

    @Test("A retained file survives the sweep; an unretained one of the same age does not")
    func retainedSurvives() throws {
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging.directory) }
        let kept = try stagedFile(in: staging, name: "kept.png", age: 3 * 24 * 60 * 60)
        let swept = try stagedFile(in: staging, name: "swept.png", age: 3 * 24 * 60 * 60)

        staging.retain(kept)
        #expect(staging.isRetained(kept))
        #expect(!staging.isRetained(swept))
        #expect(staging.sweep() == 1)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: swept.path))
    }

    @Test("Files outside staging are never marked")
    func outsideIgnored() throws {
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging.directory) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        staging.retain(outside)
        #expect(!staging.isRetained(outside))
    }
}
