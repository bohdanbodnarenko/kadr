import Foundation
import StudioSession

/// Watching the edit rather than imagining it (docs/08 §2 item 10).
///
/// The preview was scrubbing only, and said so: *"Scrubbing rather than playing. A studio
/// edit is made by moving the playhead and watching one moment at a time."* That is true of
/// framing a still and false of everything the studio is for. A zoom is a movement; a cut is
/// a join; a speed change is a rhythm. None of the three can be judged from a frozen frame,
/// so the only way to see whether an edit worked was to export it and wait minutes for the
/// answer.
///
/// Playback is an `AVPlayer` over the same clip composition the export reads, composed by
/// the same frame builder (`StudioPlaybackController`). The player is the only clock: the
/// playhead follows it while it rolls, and the soundtrack is the composition's own audio, so
/// picture and sound cannot drift apart. Paused, every playhead move is a zero-tolerance
/// seek — so "the preview is the export" holds on every frame somebody stops on.
@MainActor
public extension StudioDocumentModel {
    /// Whether the preview is making sound right now.
    var isPreviewAudioPlaying: Bool {
        playback.isAudible
    }

    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            play()
        }
    }

    func play() {
        previewPlayback.play()
    }

    func pausePlayback() {
        previewPlayback.pause()
    }

    /// Releases the player and its decoder. Closing the window has to call this; pausing
    /// alone leaves an `AVPlayer` item sitting on a composition.
    func stopPlayback() {
        previewPlayback.stop()
    }

    // MARK: - Stepping

    /// Moves the playhead by whole frames, which is the unit a cut is chosen in.
    ///
    /// Pausing first, because stepping while playing is a fight between two things moving
    /// the same value and the user always loses it.
    func step(frames: Int) {
        pausePlayback()
        let frameDuration = 1.0 / Double(max(manifest.frameRate, 1))
        playhead += Double(frames) * frameDuration
    }

    func step(seconds: TimeInterval) {
        pausePlayback()
        playhead += seconds
    }

    /// Jumps to the previous or next edit point: a clip boundary, or either end
    /// (docs/17 T-STU-11, ↑ and ↓).
    func seekToEditPoint(forward: Bool) {
        pausePlayback()
        let points = [0] + clipEnds
        let epsilon = 0.5 / Double(max(manifest.frameRate, 1))
        if forward {
            playhead = points.first { $0 > playhead + epsilon } ?? edit.duration
        } else {
            playhead = points.last { $0 < playhead - epsilon } ?? 0
        }
    }

    enum Shuttle {
        case reverse, stop, forward
    }

    /// J, K and L (docs/17 T-STU-11). L plays, and a second L doubles the speed; K stops;
    /// J plays backwards, twice as fast on a second press (docs/18 T-STU-11). A preview the
    /// player cannot run in reverse falls back to stepping back a second, or two, per press.
    func shuttle(_ direction: Shuttle) {
        switch direction {
        case .stop:
            shuttleSpeed = 0
            pausePlayback()
        case .forward:
            shuttleSpeed = isPlaying && shuttleSpeed >= 1 ? 2 : 1
            previewPlayback.setRate(Float(shuttleSpeed))
            if !isPlaying {
                play()
            }
        case .reverse:
            let reversing = isPlaying && shuttleSpeed < 0
            shuttleSpeed = shuttleSpeed <= -1 ? -2 : -1
            if isPlaying, !reversing {
                // Playing forwards: J turns it round rather than speeding it up.
                pausePlayback()
                shuttleSpeed = -1
            }
            if !previewPlayback.playReverse(speed: Float(-shuttleSpeed)) {
                step(seconds: Double(shuttleSpeed))
            }
        }
    }

    /// Jumps to the start of the edit.
    func seekToStart() {
        pausePlayback()
        playhead = 0
    }

    /// Jumps to the end of the edit.
    func seekToEnd() {
        pausePlayback()
        playhead = edit.duration
    }
}

extension StudioDocumentModel {
    /// The playback controller, bound to this model.
    var previewPlayback: StudioPlaybackController {
        playback.attach(self)
        return playback
    }
}
