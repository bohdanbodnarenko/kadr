import AVFoundation
import Foundation
import StudioSession
import Testing
@testable import EditorUI

@MainActor
@Suite("Studio soundtrack")
struct StudioAudioEditTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-studio-audio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(in folder: URL) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 10,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    private func writeSilentWav(seconds: Double, to url: URL) throws {
        let sampleRate: UInt32 = 44100
        let samples = UInt32((seconds * Double(sampleRate)).rounded())
        let dataSize = samples * 2
        var data = Data()
        func ascii(_ text: String) {
            data.append(contentsOf: text.utf8)
        }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF")
        u32(36 + dataSize)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(sampleRate)
        u32(sampleRate * 2)
        u16(2)
        u16(16)
        ascii("data")
        u32(dataSize)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url)
    }

    @Test("Importing a soundtrack copies it into the session and the edit")
    func importCopiesTheFile() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let wav = folder.appendingPathComponent("Voice Over.wav")
        try writeSilentWav(seconds: 1, to: wav)

        await studio.importSoundtrack(from: wav)
        #expect(studio.edit.soundtrackFileName == "soundtrack.wav")
        #expect(studio.edit.soundtrackDisplayName == "Voice Over")
        #expect(studio.hasImportedSoundtrack)
        #expect(studio.session.soundtrackURLs.count == 1)
        #expect(studio.failure == nil)
    }

    @Test("A file with no audio is refused")
    func importRejectsNotes() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)

        await studio.importSoundtrack(from: notes)
        #expect(studio.edit.soundtrackFileName == nil)
        #expect(studio.failure != nil)
    }

    @Test("Removing a soundtrack forgets the file and the edit")
    func removeClearsTheImport() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let wav = folder.appendingPathComponent("voice.wav")
        try writeSilentWav(seconds: 1, to: wav)
        await studio.importSoundtrack(from: wav)

        studio.removeSoundtrack()
        #expect(studio.edit.soundtrackFileName == nil)
        #expect(studio.session.soundtrackURLs.isEmpty)
        #expect(!studio.hasImportedSoundtrack)
    }

    @Test("A recording with no soundtrack stays silent in the preview")
    func placeholderFootageHasNoPreviewAudio() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.play()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!studio.isPreviewAudioPlaying)
        studio.stopPlayback()
    }

    @Test("Playing a recording with a soundtrack starts preview audio")
    func previewPlaysImportedSoundtrack() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try await modelWithMovie(in: folder, seconds: 1)
        let wav = folder.appendingPathComponent("voice.wav")
        try writeSilentWav(seconds: 1, to: wav)
        await studio.importSoundtrack(from: wav)
        #expect(studio.failure == nil)

        studio.play()
        var heard = false
        for _ in 0 ..< 40 where !heard {
            try await Task.sleep(for: .milliseconds(50))
            heard = studio.isPreviewAudioPlaying
        }
        #expect(heard, "the preview stayed silent with a soundtrack loaded")
        studio.pausePlayback()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!studio.isPreviewAudioPlaying)
        studio.stopPlayback()
    }

    private func modelWithMovie(in folder: URL, seconds: Double) async throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        _ = try await makeMovie(seconds: seconds, in: session.directory)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 160, height: 120),
            duration: seconds,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    private func makeMovie(seconds: Double, in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("screen.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        writer.add(video)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 30)
        for frame in 0 ..< frames {
            while !video.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        video.markAsFinished()
        await writer.finishWriting()
        return url
    }
}
