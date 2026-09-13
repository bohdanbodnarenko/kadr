import AVFoundation
import Foundation
import StudioSession

/// The edited soundtrack on its own, so it can be cleaned in a tool that has no API
/// and dropped back in as a replacement (docs/09 U3.3).
///
/// The exported file is the finished cut: clips, speeds and an imported soundtrack are
/// already applied. Whatever comes back therefore lies flat on the edited timeline from
/// zero, rather than being re-cut through the clip list.
public struct StudioAudioExporter: Sendable {
    public init() {}

    public enum Format: String, Sendable, CaseIterable, Identifiable {
        case m4a
        case wav

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .m4a: "M4A"
            case .wav: "WAV"
            }
        }

        public var pathExtension: String {
            rawValue
        }

        var fileType: AVFileType {
            switch self {
            case .m4a: .m4a
            case .wav: .wav
            }
        }
    }

    public enum ExportError: Error, Equatable, Sendable {
        case noAudioTrack
        case writingFailed(String)
        case cancelled
    }

    /// Seconds of audio in `url`, or nil when the file has none.
    public static func durationIfAudio(at url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await CMTimeGetSeconds(asset.load(.duration)),
              duration.isFinite, duration > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty
        else {
            return nil
        }
        return duration
    }

    /// Writes the edited soundtrack to `destination`.
    public func export(
        screen: URL,
        clips: ClipTimeline,
        soundtrack: URL?,
        to destination: URL,
        format: Format,
        mutesAudio: Bool = false,
        mixesToMono: Bool = false
    ) async throws {
        if mutesAudio {
            throw ExportError.noAudioTrack
        }
        try Task.checkCancellation()
        let composition = try await ClipCompositionBuilder().composition(
            for: clips,
            screen: screen,
            soundtrack: soundtrack
        )
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ExportError.noAudioTrack }

        try? FileManager.default.removeItem(at: destination)
        let channels = mixesToMono ? 1 : 2
        switch format {
        case .m4a:
            if mixesToMono {
                try await exportCompressed(
                    composition,
                    tracks: tracks,
                    to: destination,
                    using: AudioWrite(
                        readerSettings: Self.pcmSettings(channels: channels),
                        writerSettings: Self.aacSettings(channels: channels),
                        fileType: .m4a
                    )
                )
            } else {
                try await exportM4A(composition, to: destination)
            }
        case .wav:
            let pcm = Self.pcmSettings(channels: channels)
            try await exportCompressed(
                composition,
                tracks: tracks,
                to: destination,
                using: AudioWrite(readerSettings: pcm, writerSettings: pcm, fileType: .wav)
            )
        }
    }

    private func exportM4A(_ composition: AVMutableComposition, to destination: URL) async throws {
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExportError.writingFailed("Could not start an M4A export.")
        }
        if #available(macOS 15.0, *) {
            do {
                try await session.export(to: destination, as: .m4a)
            } catch is CancellationError {
                throw ExportError.cancelled
            } catch {
                throw ExportError.writingFailed(error.localizedDescription)
            }
            return
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        await session.export()
        try Task.checkCancellation()
        guard session.status == .completed else {
            if session.status == .cancelled {
                throw ExportError.cancelled
            }
            throw ExportError.writingFailed(session.error?.localizedDescription ?? "M4A export failed.")
        }
    }

    private struct AudioWrite {
        var readerSettings: [String: Any]
        var writerSettings: [String: Any]
        var fileType: AVFileType
    }

    private func exportCompressed(
        _ composition: AVMutableComposition,
        tracks: [AVAssetTrack],
        to destination: URL,
        using spec: AudioWrite
    ) async throws {
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: spec.readerSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ExportError.writingFailed("Could not read the soundtrack as PCM.")
        }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: spec.fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: spec.writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw ExportError.writingFailed("Could not start an audio writer.")
        }
        writer.add(input)
        try await pump(output, from: reader, into: input, writer: writer, destination: destination)
    }

    private static func pcmSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static func aacSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 128_000
        ]
    }

    private func pump(
        _ output: AVAssetReaderAudioMixOutput,
        from reader: AVAssetReader,
        into input: AVAssetWriterInput,
        writer: AVAssetWriter,
        destination: URL
    ) async throws {
        guard reader.startReading() else {
            throw ExportError.writingFailed(reader.error?.localizedDescription ?? "Could not read audio.")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ExportError.writingFailed(writer.error?.localizedDescription ?? "Could not write WAV.")
        }
        writer.startSession(atSourceTime: .zero)

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
            guard input.append(sample) else {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destination)
                throw ExportError.writingFailed(writer.error?.localizedDescription ?? "WAV append failed.")
            }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.writingFailed(reader.error?.localizedDescription ?? "Reading audio failed.")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            if writer.status == .cancelled {
                throw ExportError.cancelled
            }
            throw ExportError.writingFailed(writer.error?.localizedDescription ?? "WAV export failed.")
        }
    }
}
