import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// Stand-in PNG bytes: the model never decodes the image, it only carries it.
private let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x42, count: 512))

private func makeContents() -> KadrDocumentFile.Contents {
    var document = AnnotationDocument(baseImage: BaseImageReference(
        size: CGSize(width: 1280, height: 800),
        scale: 2
    ))
    document.add(.arrow(ArrowSpec(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 200, y: 120))))
    document.add(.text(TextSpec(string: "Look here", rect: CGRect(x: 20, y: 20, width: 200, height: 40))))
    document.add(.redaction(RedactionSpec(
        rect: CGRect(x: 0, y: 0, width: 100, height: 40),
        style: .defaultPixelate
    )))
    document.add(.counter(CounterSpec(center: CGPoint(x: 60, y: 60))))
    return KadrDocumentFile.Contents(document: document, baseImagePNG: fakePNG)
}

@Suite("Store-only zip")
struct ZipArchiveTests {
    @Test("Entries round-trip through the archive")
    func roundTrip() throws {
        let entries = [
            ZipArchive.Entry(name: "base.png", data: fakePNG),
            ZipArchive.Entry(name: "commands.json", data: Data(#"{"a":1}"#.utf8))
        ]
        let archive = ZipArchive.archive(entries)
        let read = try ZipArchive.entries(in: archive)

        #expect(read == entries)
    }

    @Test("The archive starts with a local file header, so other tools recognise it")
    func hasZipSignature() {
        let archive = ZipArchive.archive([ZipArchive.Entry(name: "a.txt", data: Data("hi".utf8))])
        #expect(Array(archive.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
    }

    @Test("CRC-32 matches the standard, which is what makes other tools accept the file")
    func crcMatchesStandard() {
        // The canonical CRC-32 of "123456789".
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipArchive.crc32(Data()) == 0)
    }

    @Test("An empty entry survives the round-trip")
    func emptyEntry() throws {
        let archive = ZipArchive.archive([ZipArchive.Entry(name: "empty", data: Data())])
        let read = try ZipArchive.entries(in: archive)
        #expect(read.first?.data.isEmpty == true)
    }

    @Test("Bytes that are not a zip are rejected")
    func rejectsGarbage() {
        #expect(throws: ZipArchive.ArchiveError.notAZipArchive) {
            try ZipArchive.entries(in: Data(repeating: 0, count: 64))
        }
        #expect(throws: ZipArchive.ArchiveError.notAZipArchive) {
            try ZipArchive.entries(in: Data("no".utf8))
        }
    }

    @Test("A truncated archive is refused rather than read past its end")
    func rejectsTruncated() {
        let archive = ZipArchive.archive([ZipArchive.Entry(name: "a", data: Data(repeating: 7, count: 100))])
        let truncated = archive.prefix(45)
        #expect(throws: (any Error).self) {
            try ZipArchive.entries(in: Data(truncated))
        }
    }
}

@Suite("The .kadr file")
struct KadrDocumentFileTests {
    @Test("A document round-trips through a .kadr file unchanged")
    func roundTrip() throws {
        let contents = makeContents()
        let data = try KadrDocumentFile.data(for: contents)
        let restored = try KadrDocumentFile.contents(of: data)

        #expect(restored.document.commands == contents.document.commands)
        #expect(restored.document.baseImage == contents.document.baseImage)
        #expect(restored.baseImagePNG == fakePNG)
    }

    @Test("A restored document starts with a clean history rather than someone else's")
    func historyIsNotSerialised() throws {
        var contents = makeContents()
        contents.document.undo()
        let restored = try KadrDocumentFile.contents(of: KadrDocumentFile.data(for: contents))

        #expect(restored.document.canUndo == false)
        #expect(restored.document.canRedo == false)
    }

    @Test("The file round-trips through disk")
    func writesAndReads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-test-\(UUID().uuidString).kadr")
        defer { try? FileManager.default.removeItem(at: url) }

        let contents = makeContents()
        try KadrDocumentFile.write(contents, to: url)
        let restored = try KadrDocumentFile.read(from: url)

        #expect(restored.document.commands == contents.document.commands)
    }

    @Test("A .kadr is a real zip containing the two documented entries")
    func layout() throws {
        let data = try KadrDocumentFile.data(for: makeContents())
        let names = try ZipArchive.entries(in: data).map(\.name)
        #expect(names.sorted() == ["base.png", "commands.json"])
    }

    @Test("An archive missing the base image is refused")
    func missingBaseImage() throws {
        let json = try JSONEncoder().encode(KadrDocumentFile.Payload(
            version: 1,
            baseImage: BaseImageReference(size: .zero),
            commands: []
        ))
        let archive = ZipArchive.archive([ZipArchive.Entry(name: "commands.json", data: json)])

        #expect(throws: KadrDocumentFile.FileError.missingEntry("base.png")) {
            try KadrDocumentFile.contents(of: archive)
        }
    }

    @Test("An archive missing the commands is refused")
    func missingCommands() {
        let archive = ZipArchive.archive([ZipArchive.Entry(name: "base.png", data: fakePNG)])
        #expect(throws: KadrDocumentFile.FileError.missingEntry("commands.json")) {
            try KadrDocumentFile.contents(of: archive)
        }
    }

    @Test("A file from a newer Kadr is refused rather than half-read")
    func rejectsNewerVersions() throws {
        let json = try JSONEncoder().encode(KadrDocumentFile.Payload(
            version: KadrDocumentFile.currentVersion + 1,
            baseImage: BaseImageReference(size: .zero),
            commands: []
        ))
        let archive = ZipArchive.archive([
            ZipArchive.Entry(name: "base.png", data: fakePNG),
            ZipArchive.Entry(name: "commands.json", data: json)
        ])

        #expect(throws: KadrDocumentFile.FileError.unsupportedVersion(KadrDocumentFile.currentVersion + 1)) {
            try KadrDocumentFile.contents(of: archive)
        }
    }

    @Test("Malformed JSON is reported as malformed")
    func rejectsBadJSON() {
        let archive = ZipArchive.archive([
            ZipArchive.Entry(name: "base.png", data: fakePNG),
            ZipArchive.Entry(name: "commands.json", data: Data("not json".utf8))
        ])
        #expect(throws: KadrDocumentFile.FileError.self) {
            try KadrDocumentFile.contents(of: archive)
        }
    }
}

@Suite("Style memory")
struct StyleMemoryTests {
    @Test("Each tool starts with a sensible style")
    func defaults() {
        let memory = StyleMemory()
        #expect(memory.stroke(for: .arrow).color == .annotationRed)
        #expect(memory.stroke(for: .highlighter).width == 20)
        #expect(memory.stroke(for: .freehand).width == 3)
        #expect(memory.fill(for: .shape).color == nil)
    }

    @Test("A style set on one tool does not leak into another")
    func perToolIsolation() {
        var memory = StyleMemory()
        memory.remember(StrokeStyle(color: .black, width: 12), for: .arrow)

        #expect(memory.stroke(for: .arrow).width == 12)
        #expect(memory.stroke(for: .shape).width == StrokeStyle().width)
    }

    @Test("Memory round-trips through JSON, so it survives a restart")
    func codable() throws {
        var memory = StyleMemory()
        memory.remember(StrokeStyle(color: .white, width: 8), for: .shape)
        memory.remember(FillStyle(color: .black), for: .shape)
        memory.lastArrowHead = .concave
        memory.lastTextStyle = TextStyle(fontSize: 32)
        memory.lastRedactionStyle = .defaultPixelate

        let data = try JSONEncoder().encode(memory)
        let restored = try JSONDecoder().decode(StyleMemory.self, from: data)

        #expect(restored == memory)
        #expect(restored.stroke(for: .shape).width == 8)
        #expect(restored.lastArrowHead == .concave)
    }

    @Test("Turning fill off keeps the last opacity for the next fill")
    func fillOpacitySurvivesToggleOff() {
        var memory = StyleMemory()
        #expect(abs(memory.lastFillOpacity - FillStyle.defaultAlpha) < 0.001)

        memory.remember(FillStyle(color: .annotationRed.withAlpha(0.7)), for: .shape)
        #expect(abs(memory.lastFillOpacity - 0.7) < 0.001)

        memory.remember(.none, for: .shape)
        #expect(memory.fill(for: .shape).color == nil)
        #expect(abs(memory.lastFillOpacity - 0.7) < 0.001)
    }
}
