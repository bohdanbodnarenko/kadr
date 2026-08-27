import CoreGraphics
import Foundation
import Shared
import Testing
@testable import MediaExport

private func makeImage() -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: 10,
        height: 10,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }
    return image
}

private func temporaryDirectory(_ name: String = "dir") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Export policy")
struct CaptureExporterTests {
    private func exporter(staging: URL) -> CaptureExporter {
        CaptureExporter(staging: StagingArea(directory: staging))
    }

    @Test("Clipboard-only leaves no file behind")
    func clipboardOnly() throws {
        let save = temporaryDirectory("save")
        var copied: Data?
        let result = try exporter(staging: temporaryDirectory("stage")).export(
            makeImage(),
            policy: ExportPolicy(copiesToClipboard: true, savesToFolder: false, staging: false),
            saveFolder: save,
            copyData: { data, _ in
                copied = data
                return true
            }
        )

        #expect(result.copiedToClipboard)
        #expect(result.fileURL == nil)
        #expect(copied?.isEmpty == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).isEmpty)
    }

    @Test("Save-only writes to the save folder and skips the clipboard")
    func saveOnly() throws {
        let save = temporaryDirectory("save")
        var copyCalls = 0
        let result = try exporter(staging: temporaryDirectory("stage")).export(
            makeImage(),
            policy: ExportPolicy(copiesToClipboard: false, savesToFolder: true, staging: false),
            saveFolder: save,
            copyData: { _, _ in
                copyCalls += 1
                return true
            }
        )

        #expect(copyCalls == 0)
        #expect(result.copiedToClipboard == false)
        #expect(result.isStaged == false)
        #expect(result.fileURL?.deletingLastPathComponent().path == save.path)
    }

    @Test("Both does both, encoding only once")
    func copyAndSave() throws {
        let save = temporaryDirectory("save")
        var copies = 0
        let result = try exporter(staging: temporaryDirectory("stage")).export(
            makeImage(),
            policy: ExportPolicy(copiesToClipboard: true, savesToFolder: true, staging: false),
            saveFolder: save,
            copyData: { _, _ in
                copies += 1
                return true
            }
        )

        #expect(copies == 1)
        #expect(result.copiedToClipboard)
        #expect(result.fileURL != nil)
    }

    @Test("Overlay-only stages the file instead of dropping it on the Desktop")
    func overlayOnlyStages() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let result = try exporter(staging: stage).export(
            makeImage(),
            policy: ExportPolicy(copiesToClipboard: false, savesToFolder: false, staging: true),
            saveFolder: save
        )

        #expect(result.isStaged)
        #expect(result.fileURL?.deletingLastPathComponent().path == stage.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).isEmpty)
    }

    @Test("Finalising moves a staged capture into the save folder")
    func finalizeStaged() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let exporter = exporter(staging: stage)
        let staged = try exporter.export(
            makeImage(),
            policy: ExportPolicy(copiesToClipboard: false, savesToFolder: false, staging: true),
            saveFolder: save
        )
        let stagedURL = try #require(staged.fileURL)

        let final = try exporter.finalizeStaged(stagedURL, into: save)

        #expect(final.deletingLastPathComponent().path == save.path)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: final.path))
    }

    @Test("Finalising onto an existing name does not overwrite it")
    func finalizeNeverOverwrites() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let exporter = exporter(staging: stage)
        let template = FilenameTemplate("shot")

        let first = try exporter.export(
            makeImage(),
            policy: ExportPolicy(copiesToClipboard: false, savesToFolder: false, staging: true),
            saveFolder: save,
            template: template
        )
        let firstFinal = try exporter.finalizeStaged(#require(first.fileURL), into: save)

        let second = try exporter.export(
            makeImage(),
            policy: ExportPolicy(copiesToClipboard: false, savesToFolder: false, staging: true),
            saveFolder: save,
            template: template
        )
        let secondFinal = try exporter.finalizeStaged(#require(second.fileURL), into: save)

        #expect(firstFinal.lastPathComponent == "shot.png")
        #expect(secondFinal.lastPathComponent == "shot (2).png")
    }

    @Test("An unwritable format fails instead of producing an empty file")
    func unwritableFormat() {
        let save = temporaryDirectory("save")
        #expect(throws: ExportError.unsupportedFormat(.webp)) {
            try exporter(staging: temporaryDirectory("stage")).export(
                makeImage(),
                policy: ExportPolicy(copiesToClipboard: false, savesToFolder: true, staging: false),
                saveFolder: save,
                options: EncodingOptions(format: .webp)
            )
        }
    }
}

@Suite("Staging retention")
struct StagingAreaTests {
    @Test("Files past the retention window are swept, recent ones are not")
    func sweepsStaleFiles() throws {
        let directory = temporaryDirectory("stage")
        let staging = StagingArea(directory: directory, retention: 60)

        let stale = directory.appendingPathComponent("old.png")
        let fresh = directory.appendingPathComponent("new.png")
        try Data([0]).write(to: stale)
        try Data([0]).write(to: fresh)

        let longAgo = Date(timeIntervalSince1970: 0)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: stale.path)

        let removed = staging.sweep(now: Date(timeIntervalSince1970: 10000))

        #expect(removed == 1)
        #expect(FileManager.default.fileExists(atPath: stale.path) == false)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("Sweeping a directory that does not exist yet is harmless")
    func sweepMissingDirectory() {
        let staging = StagingArea(directory: URL(fileURLWithPath: "/nonexistent/kadr-staging"))
        #expect(staging.sweep() == 0)
    }

    @Test("The default staging area is under Application Support, per doc 04 §9")
    func defaultLocation() {
        let path = StagingArea.defaultDirectory.path
        #expect(path.contains("Application Support/Kadr/Staging"))
    }
}
