import AVFoundation
import Foundation
import Shared
import Testing
@testable import VisionServices

@Suite("Audio extraction")
struct AudioExtractorTests {
    @Test("A file with no audio is an error")
    func refusesSilentVideo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("silent.mov")
        try await Self.writeSilentMovie(to: movie)
        await #expect(throws: VisionServiceError.transcriptionFailed) {
            _ = try await AudioExtractor().extract(from: movie, selection: .preferred)
        }
    }

    @Test("Track kind: one track is mixed, two tracks are system then microphone")
    func trackKinds() {
        #expect(AudioExtractor.kind(index: 0, count: 1) == .mixed)
        #expect(AudioExtractor.kind(index: 0, count: 2) == .system)
        #expect(AudioExtractor.kind(index: 1, count: 2) == .microphone)
    }

    @Test("The extractor never opens the video container with AVAudioFile (T-C1)")
    func containerIsNotOpenedAsAudioFile() throws {
        let extractor = try Self.source(of: "AudioExtractor.swift")
        let handler = try Self.source(of: "SpeechXPCHandler.swift")
        #expect(extractor.contains("AVURLAsset"))
        #expect(extractor.contains("AVAssetReader"))
        #expect(!extractor.contains("AVAudioFile(forReading"))
        #expect(handler.contains("AudioExtractor()"))
        #expect(!handler.contains("AVAudioFile(forReading"))
    }

    @Test("A written WAV is 16-bit PCM that AVAudioFile will open")
    func wavIsReadable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        var pcm = Data()
        for sampleIndex in 0 ..< 1600 {
            var sample = Int16(sampleIndex % 100)
            pcm.append(Data(bytes: &sample, count: 2))
        }
        try WAVFile.write(pcm: pcm, sampleRate: 16000, channels: 1, to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
    }

    private static func writeSilentMovie(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 80,
            AVVideoHeightKey: 80
        ])
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 80,
                kCVPixelBufferHeightKey as String: 80
            ]
        )
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 8 {
            while !video.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            if let pixelBuffer {
                adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            }
        }
        video.markAsFinished()
        await writer.finishWriting()
    }

    private static func source(of name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VisionServices/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
