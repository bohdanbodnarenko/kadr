import CoreGraphics
import Foundation
import Shared
import Testing
@testable import MediaExport

/// docs/17 T-OUT-5 and T-OUT-6: a refused save folder must not lose the capture, a long
/// name must not fail the write, and copies of files Kadr does not own never replace
/// anything.
@Suite("Save failure recovery")
struct SaveFailureRecoveryTests {
    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A read-only save folder stages the capture and says why")
    func readOnlyFolderFallsBackToStaging() throws {
        let save = try temporaryDirectory("readonly")
        let stage = try temporaryDirectory("stage")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: save.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: save.path) }

        let result = try CaptureExporter(staging: StagingArea(directory: stage)).export(
            makeImage(),
            policy: ExportPolicy(copiesToClipboard: false, savesToFolder: true, staging: false),
            saveFolder: save
        )

        let file = try #require(result.fileURL)
        #expect(result.isStaged)
        #expect(result.saveFailure != nil)
        #expect(file.deletingLastPathComponent().standardizedFileURL.path == stage.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A writable save folder reports no failure")
    func healthyFolderHasNoFailure() throws {
        let result = try CaptureExporter(staging: StagingArea(directory: temporaryDirectory("stage"))).export(
            makeImage(),
            policy: ExportPolicy(copiesToClipboard: false, savesToFolder: true, staging: false),
            saveFolder: temporaryDirectory("save")
        )
        #expect(result.saveFailure == nil)
        #expect(!result.isStaged)
    }

    @Test("Expanded names are capped in bytes, on a character boundary", arguments: [
        (String(repeating: "a", count: 300), 200),
        (String(repeating: "é", count: 150), 200),
        (String(repeating: "🙂", count: 80), 200),
        ("short", 5)
    ])
    func namesAreCapped(input: String, expectedBytes: Int) {
        let expanded = FilenameTemplate(input).expand(FilenameContext())
        #expect(expanded.utf8.count == expectedBytes)
        // Still valid text: nothing split mid-scalar.
        #expect(String(bytes: Array(expanded.utf8), encoding: .utf8) == expanded)
    }

    @Test("A 255-byte window title still writes")
    func longNameWrites() throws {
        let save = try temporaryDirectory("long")
        let url = try CaptureFileWriter().write(
            makeImage(),
            to: save,
            template: FilenameTemplate("{app}"),
            context: FilenameContext(applicationName: String(repeating: "Ж", count: 200))
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Copying under a taken name picks the next free one and keeps the original")
    func copyNeverReplaces() throws {
        let source = try temporaryDirectory("src").appendingPathComponent("blob.png")
        try Data([1, 2, 3]).write(to: source)
        let folder = try temporaryDirectory("dest")

        let first = try StagingArea.copy(source, named: "Screenshot.png", into: folder)
        let second = try StagingArea.copy(source, named: "Screenshot.png", into: folder)

        #expect(first.lastPathComponent == "Screenshot.png")
        #expect(second.lastPathComponent == "Screenshot (2).png")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("A copy with no extension in the name keeps the source's")
    func copyKeepsSourceExtension() throws {
        let source = try temporaryDirectory("src").appendingPathComponent("3fa9c1.heic")
        try Data([1]).write(to: source)
        let copy = try StagingArea(directory: temporaryDirectory("stage")).adoptCopy(of: source, named: "Receipt")
        #expect(copy.lastPathComponent == "Receipt.heic")
    }
}
