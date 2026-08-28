import AVFoundation
import Foundation
import os
import Shared

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
    public func composition(
        for timeline: ClipTimeline,
        screen: URL,
        camera: URL? = nil
    ) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: screen)
        // `try?` rather than propagating: a file that is not a movie and a movie with no
        // video track are the same problem to a caller, and AVFoundation's own error for
        // the first says "media format is not supported", which explains less.
        guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
            throw BuildError.noVideoTrack
        }
        let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first

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
            try? await insertCamera(camera, into: composition, timeline: timeline)
        }
        return composition
    }

    /// Adds the camera recording, cut and retimed the same way the screen was.
    ///
    /// Best-effort: a camera file that will not open costs the bubble, not the export. A
    /// recording without its webcam is still the recording.
    private func insertCamera(
        _ url: URL,
        into composition: AVMutableComposition,
        timeline: ClipTimeline
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
            // The camera may be shorter than the screen — it starts when the user turns it
            // on. A clip past its end contributes nothing rather than failing the export.
            guard clip.sourceStart < cameraDuration else { break }
            let available = min(clip.sourceDuration, cameraDuration - clip.sourceStart)
            let cursor = CMTime(seconds: elapsed, preferredTimescale: 600)
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: available, preferredTimescale: 600)
            )
            try? track.insertTimeRange(range, of: sourceVideo, at: cursor)

            if clip.speed != 1 {
                let inserted = CMTimeRange(start: cursor, duration: range.duration)
                let scaled = CMTime(seconds: available / clip.speed, preferredTimescale: 600)
                track.scaleTimeRange(inserted, toDuration: scaled)
                elapsed += available / clip.speed
            } else {
                elapsed += available
            }
        }
    }
}
