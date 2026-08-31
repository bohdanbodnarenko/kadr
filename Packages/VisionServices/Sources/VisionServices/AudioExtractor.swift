import AVFoundation
import Foundation
import os
import Shared

/// Pulls 16 kHz mono PCM out of a video container (docs/13 T0.1).
///
/// `AVAudioFile` sniffs the container and refuses an MP4 that happens to be named
/// `.mov` and to carry a video track — which is exactly what Kadr writes. Every other
/// consumer in the repo uses `AVURLAsset`; this is the speech path catching up.
///
/// When the file has two audio tracks, `SegmentWriter` added system audio first and the
/// microphone second. Preferring the last track is what makes "remove my filler words"
/// listen to the narrator rather than to the video they were talking over (docs/13 T-H1).
public struct AudioExtractor: Sendable {
    public static let sampleRate: Double = 16000
    public static let channels = 1

    private let logger = KadrLog.logger(.recording)
    private let signposter = KadrLog.signposter(.recording)

    public init() {}

    public struct Extracted: Sendable {
        public let url: URL
        public let track: SpeechTrackKind
        public let duration: TimeInterval
    }

    public func extract(
        from mediaURL: URL,
        selection: SpeechTrackSelection
    ) async throws -> [Extracted] {
        let interval = signposter.beginInterval("speech.extract")
        defer { signposter.endInterval("speech.extract", interval) }

        let asset = AVURLAsset(url: mediaURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw VisionServiceError.transcriptionFailed }

        let chosen: [(AVAssetTrack, SpeechTrackKind)] = switch selection {
        case .preferred:
            [Self.preferred(tracks)]
        case .all:
            tracks.enumerated().map { index, track in
                (track, Self.kind(index: index, count: tracks.count))
            }
        }

        var extracted: [Extracted] = []
        for (track, kind) in chosen {
            try Task.checkCancellation()
            try await extracted.append(pull(track, of: asset, kind: kind))
        }
        return extracted
    }

    /// Last track when there are two (the microphone); otherwise the only one.
    public static func preferred(_ tracks: [AVAssetTrack]) -> (AVAssetTrack, SpeechTrackKind) {
        let index = tracks.count > 1 ? tracks.count - 1 : 0
        return (tracks[index], kind(index: index, count: tracks.count))
    }

    public static func kind(index: Int, count: Int) -> SpeechTrackKind {
        guard count > 1 else { return .mixed }
        return index == 0 ? .system : .microphone
    }

    private func pull(
        _ track: AVAssetTrack,
        of asset: AVAsset,
        kind: SpeechTrackKind
    ) async throws -> Extracted {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VisionServiceError.transcriptionFailed
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VisionServiceError.transcriptionFailed
        }

        var pcm = Data()
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            if let pointer, length > 0 {
                pcm.append(UnsafeBufferPointer(start: pointer, count: length))
            }
        }
        if reader.status == .failed {
            throw VisionServiceError.transcriptionFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-speech-\(UUID().uuidString).wav")
        try WAVFile.write(pcm: pcm, sampleRate: Self.sampleRate, channels: Self.channels, to: url)
        let duration = Double(pcm.count / 2) / Self.sampleRate
        logger.info("Extracted \(duration, privacy: .public)s of \(kind.rawValue, privacy: .public) audio")
        return Extracted(url: url, track: kind, duration: duration)
    }
}

/// A canonical 16-bit PCM WAV, which both speech APIs will actually open.
enum WAVFile {
    static func write(pcm: Data, sampleRate: Double, channels: Int, to url: URL) throws {
        let byteRate = Int(sampleRate) * channels * 2
        var header = Data()
        func append(_ string: String) {
            header.append(contentsOf: string.utf8)
        }
        func appendU32(_ value: UInt32) {
            var value = value.littleEndian
            header.append(Data(bytes: &value, count: 4))
        }
        func appendU16(_ value: UInt16) {
            var value = value.littleEndian
            header.append(Data(bytes: &value, count: 2))
        }

        append("RIFF")
        appendU32(UInt32(36 + pcm.count))
        append("WAVE")
        append("fmt ")
        appendU32(16)
        appendU16(1)
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(byteRate))
        appendU16(UInt16(channels * 2))
        appendU16(16)
        append("data")
        appendU32(UInt32(pcm.count))

        try (header + pcm).write(to: url, options: .atomic)
    }
}
