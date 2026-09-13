import AVFoundation
import Foundation
import os
import Shared
import StudioSession

/// Assembles the clips into something AVFoundation can play and export (docs/09 U3.4).
///
/// Edit-side AVFoundation only. Nothing here captures anything — the capture side stays in
/// the agent with the TCC grant, and this package never learns what a display is.
///
/// The composition is rebuilt from the timeline rather than mutated in place, because a
/// composition that has been edited a hundred times accumulates segment boundaries that no
/// longer mean anything, and debugging one is worse than rebuilding it.
public struct ClipCompositionBuilder: Sendable {
    private let logger = KadrLog.logger(.recording)

    public init() {}

    public enum BuildError: Error, Equatable, Sendable {
        case noVideoTrack
        case couldNotInsert
    }

    /// A composition playing `timeline`'s clips at their own speeds.
    ///
    /// Audio is scaled alongside video in the same call, which is what keeps it in sync: a
    /// composition that speeds the picture and leaves the sound alone drifts by exactly the
    /// amount it was sped up, and the drift compounds with every clip.
    /// - Parameter cameraStartOffset: how far into the recording the camera's first frame
    ///   landed. Camera time zero is screen time `cameraStartOffset`, so every camera range
    ///   is shifted back by it — without which the bubble is permanently ahead of the
    ///   picture by however long the capture session took to wake up (docs/10 R0.5).
    /// - Parameter soundtrack: an imported file that stands in for the recording's own
    ///   audio. It is laid on the edited timeline from zero rather than re-cut through
    ///   the clips, because the import *is* the finished cut's soundtrack.
    public func composition(
        for timeline: ClipTimeline,
        screen: URL,
        camera: URL? = nil,
        cameraStartOffset: TimeInterval = 0,
        soundtrack: URL? = nil,
        includeAudio: Bool = true
    ) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: screen)
        // `try?` rather than propagating: a file that is not a movie and a movie with no
        // video track are the same problem to a caller, and AVFoundation's own error for
        // the first says "media format is not supported", which explains less.
        guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
            throw BuildError.noVideoTrack
        }
        let replacement = includeAudio ? await soundtrackFile(at: soundtrack) : nil
        let sourceAudio: AVAssetTrack?
        if includeAudio, replacement == nil {
            sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first
        } else {
            sourceAudio = nil
        }

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw BuildError.couldNotInsert
        }
        let audio = sourceAudio == nil ? nil : composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        // Tracked in seconds and converted once per insert: `CMTime` has no compound
        // addition, and accumulating one by repeated construction invites a timescale
        // mismatch nobody notices until the audio drifts.
        var elapsed: TimeInterval = 0
        for clip in timeline.clips where clip.sourceDuration > 0 {
            let cursor = CMTime(seconds: elapsed, preferredTimescale: 600)
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)
            )
            do {
                try video.insertTimeRange(range, of: sourceVideo, at: cursor)
                if let audio, let sourceAudio {
                    try audio.insertTimeRange(range, of: sourceAudio, at: cursor)
                }
            } catch {
                logger.error("Could not insert a clip: \(error.localizedDescription, privacy: .public)")
                throw BuildError.couldNotInsert
            }

            if clip.speed != 1 {
                let inserted = CMTimeRange(start: cursor, duration: range.duration)
                let scaled = CMTime(seconds: clip.editedDuration, preferredTimescale: 600)
                // Both tracks, in the same breath: scaling the picture and leaving the
                // sound alone drifts by exactly the speed-up, and it compounds per clip.
                video.scaleTimeRange(inserted, toDuration: scaled)
                audio?.scaleTimeRange(inserted, toDuration: scaled)
                elapsed += clip.editedDuration
            } else {
                elapsed += clip.sourceDuration
            }
        }

        // The camera is a separate track rather than a burnt-in overlay, which is what
        // lets the bubble be moved, resized or removed after the fact (docs/09 U3.4).
        if let camera, FileManager.default.fileExists(atPath: camera.path) {
            try? await insertCamera(camera, into: composition, timeline: timeline, startOffset: cameraStartOffset)
        }
        if let replacement {
            try? await insertSoundtrack(replacement, into: composition, duration: elapsed)
        }
        return composition
    }

    /// The imported file, but only when it actually carries audio.
    ///
    /// A picked file with no audio track must not mute the recording: the import is a
    /// replacement, not a deletion.
    private func soundtrackFile(at url: URL?) async -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first
        else {
            return nil
        }
        _ = track
        return url
    }

    /// Adds the camera recording, cut and retimed the same way the screen was.
    ///
    /// Best-effort: a camera file that will not open costs the bubble, not the export. A
    /// recording without its webcam is still the recording.
    private func insertCamera(
        _ url: URL,
        into composition: AVMutableComposition,
        timeline: ClipTimeline,
        startOffset: TimeInterval
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            return
        }
        let cameraDuration = try await CMTimeGetSeconds(asset.load(.duration))

        var elapsed: TimeInterval = 0
        for clip in timeline.clips where clip.sourceDuration > 0 {
            // Screen time `t` is camera time `t - startOffset`: the camera woke up late, so
            // its file begins partway into the recording.
            let cameraStart = clip.sourceStart - startOffset
            // How much of this clip's head has no camera behind it at all, because the
            // device had not handed over a frame yet.
            let headShift = max(-cameraStart, 0)
            // The clip's own remaining length is a limit too (docs/11 S0.5). It was not one,
            // so a clip that starts before the camera did inserted `startOffset` more
            // camera than it holds — and `insertTimeRange` *inserts*, so the surplus pushed
            // every later segment further out, which is the same drift R0.5 fixed on the
            // `elapsed` accumulator arriving by another door.
            let available = min(
                clip.sourceDuration - headShift,
                cameraDuration - max(cameraStart, 0)
            )

            // The camera may be shorter than the screen, or may not have started until
            // after this clip — it begins when the device hands over its first frame, and
            // ends when the user stops. Either way the clip contributes no camera rather
            // than failing the export.
            if cameraStart < cameraDuration, available > 0 {
                let cursor = CMTime(seconds: elapsed + headShift, preferredTimescale: 600)
                let range = CMTimeRange(
                    start: CMTime(seconds: max(cameraStart, 0), preferredTimescale: 600),
                    duration: CMTime(seconds: available, preferredTimescale: 600)
                )
                try? track.insertTimeRange(range, of: sourceVideo, at: cursor)

                if clip.speed != 1 {
                    let inserted = CMTimeRange(start: cursor, duration: range.duration)
                    let scaled = CMTime(seconds: available / clip.speed, preferredTimescale: 600)
                    track.scaleTimeRange(inserted, toDuration: scaled)
                }
            }

            // Advanced by the clip's own edited length, never by how much camera happened
            // to be available (docs/10 R0.5). Advancing by the truncated length pulled every
            // later segment early by the shortfall, so one short camera file put the bubble
            // progressively further ahead of the picture for the rest of the recording.
            elapsed += clip.editedDuration
        }
    }

    /// Lays imported audio on the edited timeline from zero, clamped to the cut.
    ///
    /// The import is already the finished soundtrack, so it is not scaled through clips
    /// the way the recording's own audio is. A file that overruns is trimmed; a shorter
    /// one simply ends early.
    private func insertSoundtrack(
        _ url: URL,
        into composition: AVMutableComposition,
        duration: TimeInterval
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            return
        }
        let sourceDuration = await (try? CMTimeGetSeconds(asset.load(.duration))) ?? 0
        let length = min(sourceDuration, duration)
        guard length > 0.01 else { return }
        try? track.insertTimeRange(
            CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: length, preferredTimescale: 600)
            ),
            of: source,
            at: .zero
        )
    }
}
