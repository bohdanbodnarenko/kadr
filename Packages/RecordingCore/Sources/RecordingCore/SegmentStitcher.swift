import AVFoundation
import Foundation
import os
import Shared

/// Joins pause/resume segments into one file (docs/04 §4.3).
///
/// Passthrough, not re-encode. The segments already contain exactly the frames the user
/// recorded, in the codec they chose; decoding and re-encoding them would cost minutes on
/// a long recording and lose quality for nothing. Stitching is a container operation.
/// Joins finished segments into the delivered file.
///
/// A protocol so the engine's failure path is testable: the review's C3 — a failed stitch
/// leaving recording bricked — can only be pinned down by making the stitch fail on
/// purpose (docs/09 U0.3).
public protocol SegmentStitching: Sendable {
    func stitch(_ segments: [URL], to destination: URL) async throws -> URL
}

public struct SegmentStitcher: SegmentStitching {
    private let logger = KadrLog.logger(.recording)

    public init() {}

    /// Joins segments in order. One segment is moved rather than copied.
    public func stitch(_ segments: [URL], to destination: URL) async throws -> URL {
        guard !segments.isEmpty else { throw RecordingError.noFramesCaptured }

        // The common case: no pause happened, so there is nothing to join.
        if segments.count == 1 {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: segments[0], to: destination)
            return destination
        }

        let composition = try await join(segments)
        try await write(composition, to: destination)

        for segment in segments {
            try? FileManager.default.removeItem(at: segment)
        }
        let count = segments.count
        logger.info("Stitched \(count, privacy: .public) segments")
        return destination
    }

    /// Lays the segments end to end, with every audio track each one carries.
    ///
    /// Split out of `stitch` because it is the only part that is about *the recording* —
    /// the rest is a fast path and an encoder — and because the loop below decides
    /// something subtle enough to be worth reading on its own: how many audio tracks the
    /// result needs is not known until the segment that has the most of them.
    private func join(_ segments: [URL]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingError.writingFailed("could not create a video track")
        }
        var audioTracks: [AVMutableCompositionTrack] = []

        var cursor = CMTime.zero
        for segment in segments {
            let asset = AVURLAsset(url: segment)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            if let source = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
            }
            let sources = try await asset.loadTracks(withMediaType: .audio)
            while audioTracks.count < sources.count {
                guard let added = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw RecordingError.writingFailed("could not create an audio track")
                }
                audioTracks.append(added)
            }
            for (index, source) in sources.enumerated() {
                try audioTracks[index].insertTimeRange(range, of: source, at: cursor)
            }
            // Butt the next segment against this one: the gap while paused is time the
            // user chose not to record, so it must not appear in the result.
            cursor = CMTimeAdd(cursor, duration)
        }
        return composition
    }

    /// Writes the joined composition out, without re-encoding it.
    private func write(_ composition: AVMutableComposition, to destination: URL) async throws {
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw RecordingError.writingFailed("could not create an export session")
        }

        try? FileManager.default.removeItem(at: destination)
        do {
            try await export.export(to: destination, as: .mp4)
        } catch {
            throw RecordingError.writingFailed(error.localizedDescription)
        }
    }
}
