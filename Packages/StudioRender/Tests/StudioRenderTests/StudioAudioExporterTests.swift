import AVFoundation
import CoreMedia
import Foundation
import StudioSession
import Testing
@testable import StudioRender

@Suite("Studio audio exporter")
struct StudioAudioExporterTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-audio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A file with no audio is not a soundtrack")
    func durationIfAudioRejectsSilence() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)
        #expect(await StudioAudioExporter.durationIfAudio(at: notes) == nil)
    }

    @Test("A silent WAV is accepted as a soundtrack")
    func durationIfAudioReadsWav() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("voice.wav")
        try writeSilentWav(seconds: 1.5, to: wav)
        let duration = try #require(await StudioAudioExporter.durationIfAudio(at: wav))
        #expect(abs(duration - 1.5) < 0.05)
    }

    @Test("Exporting a soundtrack writes an M4A with an audio track")
    func exportM4A() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await StudioMediaFixtures.makeMovie(seconds: 1, in: folder)
        let wav = folder.appendingPathComponent("voice.wav")
        try writeSilentWav(seconds: 1, to: wav)
        let destination = folder.appendingPathComponent("out.m4a")

        try await StudioAudioExporter().export(
            screen: movie,
            clips: .whole(duration: 1),
            soundtrack: wav,
            to: destination,
            format: .m4a
        )
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty)
    }

    @Test("Mute refuses to export a soundtrack")
    func muteExportsNothing() async {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("voice.wav")
        try? writeSilentWav(seconds: 1, to: wav)
        await #expect(throws: StudioAudioExporter.ExportError.noAudioTrack) {
            try await StudioAudioExporter().export(
                screen: folder.appendingPathComponent("missing.mov"),
                clips: .whole(duration: 1),
                soundtrack: wav,
                to: folder.appendingPathComponent("out.m4a"),
                format: .m4a,
                mutesAudio: true
            )
        }
    }

    @Test("Mix to mono writes a one-channel WAV")
    func mixToMonoWritesOneChannel() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await StudioMediaFixtures.makeMovie(seconds: 1, in: folder)
        let wav = folder.appendingPathComponent("voice.wav")
        try writeSilentWav(seconds: 1, to: wav)
        let destination = folder.appendingPathComponent("out.wav")

        try await StudioAudioExporter().export(
            screen: movie,
            clips: .whole(duration: 1),
            soundtrack: wav,
            to: destination,
            format: .wav,
            mixesToMono: true
        )
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        let track = try #require(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        #expect(asbd?.pointee.mChannelsPerFrame == 1)
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
}
