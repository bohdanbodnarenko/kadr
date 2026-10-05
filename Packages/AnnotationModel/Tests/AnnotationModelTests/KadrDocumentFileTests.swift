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

    @Test("The archive starts with a local file header, so other tools recognize it")
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

    /// Published CRC-32/ISO-HDLC check values. Lengths straddle the eight-byte fold so both
    /// the sliced loop and the byte tail are exercised.
    @Test("CRC-32 matches known values", arguments: [
        ("", UInt32(0)),
        ("a", UInt32(0xE8B7_BE43)),
        ("abc", UInt32(0x3524_41C2)),
        ("12345678", UInt32(0x9AE0_DAAF)),
        ("123456789", UInt32(0xCBF4_3926)),
        ("message digest", UInt32(0x2015_9D7F)),
        ("abcdefghijklmnopqrstuvwxyz", UInt32(0x4C27_50BD)),
        ("The quick brown fox jumps over the lazy dog", UInt32(0x414F_A339))
    ])
    func crcKnownValues(input: String, expected: UInt32) {
        #expect(ZipArchive.crc32(Data(input.utf8)) == expected)
    }

    @Test("The sliced CRC agrees with the byte-at-a-time one for every tail length")
    func slicedMatchesBytewise() {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 7, 8, 9, 15, 16, 17, 63, 64, 65, 1000, 4099] {
            let bytes = (0 ..< length).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
            let data = Data(bytes)
            #expect(ZipArchive.crc32(data) == ZipArchive.crc32Bytewise(data), "length \(length)")
            // A slice starts at a non-zero index; the checksum must be of its own bytes.
            let padded = Data([0xAA, 0xBB, 0xCC] + bytes)
            let slice = padded.dropFirst(3)
            #expect(ZipArchive.crc32(slice) == ZipArchive.crc32Bytewise(data), "slice \(length)")
        }
    }

    @Test("A precomputed CRC is written as given, and matches what would be computed")
    func precomputedCRC() {
        let payload = Data(repeating: 42, count: 1000)
        let crc = KadrDocumentFile.crc32(of: payload)
        let computed = ZipArchive.archive([ZipArchive.Entry(name: "a", data: payload)])
        let supplied = ZipArchive.archive([ZipArchive.Entry(name: "a", data: payload, crc: crc)])
        #expect(computed == supplied)
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
    @Test("Supplying the base image's CRC writes the same file as computing it")
    func cachedBaseCRC() throws {
        var contents = makeContents()
        let computed = try KadrDocumentFile.data(for: contents)
        contents.baseImageCRC32 = KadrDocumentFile.crc32(of: contents.baseImagePNG)
        #expect(try KadrDocumentFile.data(for: contents) == computed)
    }

    @Test("A document round-trips through a .kadr file unchanged")
    func roundTrip() throws {
        let contents = makeContents()
        let data = try KadrDocumentFile.data(for: contents)
        let restored = try KadrDocumentFile.contents(of: data)

        #expect(restored.document.commands == contents.document.commands)
        #expect(restored.document.baseImage == contents.document.baseImage)
        #expect(restored.baseImagePNG == fakePNG)
    }

    @Test("A rotated document reopens already rotated")
    func orientationIsSerialised() throws {
        var contents = makeContents()
        contents.document.rotateClockwise()
        let restored = try KadrDocumentFile.contents(of: KadrDocumentFile.data(for: contents))
        #expect(restored.document.orientation.quarterTurnsCW == 1)
        #expect(restored.document.commands == contents.document.commands)
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
        #expect(memory.lastCounterSize == .medium)
        #expect(memory.lastCounterFill == .annotationRed)
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
        memory.lastCounterSize = .large
        memory.lastCounterFill = .black

        let data = try JSONEncoder().encode(memory)
        let restored = try JSONDecoder().decode(StyleMemory.self, from: data)

        #expect(restored == memory)
        #expect(restored.stroke(for: .shape).width == 8)
        #expect(restored.lastArrowHead == .concave)
        #expect(restored.lastCounterSize == .large)
        #expect(restored.lastCounterFill == .black)
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

/// What a project from another build says when it cannot be read (docs/18 ED-8).
@Suite("Reading projects from other builds")
struct KadrDocumentFileCompatibilityTests {
    private func archive(json: String) -> Data {
        ZipArchive.archive([
            ZipArchive.Entry(name: KadrDocumentFile.baseImageEntry, data: fakePNG),
            ZipArchive.Entry(name: KadrDocumentFile.commandsEntry, data: Data(json.utf8))
        ])
    }

    @Test("A newer file version is named as such, even when it does not decode")
    func newerVersion() {
        #expect(throws: KadrDocumentFile.FileError.unsupportedVersion(9)) {
            try KadrDocumentFile.contents(of: archive(json: #"{"version":9,"whatever":true}"#))
        }
    }

    @Test("An unknown command type is a newer Kadr, not a broken file")
    func unknownCommand() throws {
        let base = try JSONEncoder().encode(makeContents().document.baseImage)
        let json = try #"{"version":1,"baseImage":"# + #require(String(bytes: base, encoding: .utf8))
            + #","commands":[{"hologram":{"id":"x"}}]}"#
        #expect(throws: KadrDocumentFile.FileError.newerCommands) {
            try KadrDocumentFile.contents(of: archive(json: json))
        }
    }

    @Test("Export Size travels with the project; native size writes nothing", arguments: [
        (0.5 as Double?, 0.5 as Double?), (1, nil), (nil, nil)
    ])
    func exportScaleRoundTrip(saved: Double?, expected: Double?) throws {
        var contents = makeContents()
        contents.exportScale = saved
        let read = try KadrDocumentFile.contents(of: KadrDocumentFile.data(for: contents))
        #expect(read.exportScale == expected)
    }

    @Test("Errors read as sentences, not type names")
    func messages() {
        let errors: [KadrDocumentFile.FileError] = [
            .unsupportedVersion(2), .newerCommands, .malformed("x"), .missingEntry("a")
        ]
        for error in errors {
            let text = error.localizedDescription
            #expect(!text.contains("FileError"))
            #expect(text.hasSuffix("."))
        }
    }
}
