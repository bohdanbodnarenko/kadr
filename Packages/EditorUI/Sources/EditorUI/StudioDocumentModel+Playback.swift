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
/// Playback is a *preview*, and deliberately not a promise of exactness. While it runs the
/// frame generator is allowed a tenth of a second of slack so it can keep up, and frames are
/// dropped rather than queued when it cannot. The moment it pauses, the exact frame is drawn
/// again — so "the preview is the export" still holds everywhere it is being relied on to.
/// The soundtrack plays from the same clip composition the export muxes, so a cut or an
/// imported file is heard here rather than only in the finished movie.
@MainActor
public extension StudioDocumentModel {
    /// Whether the edit is playing.
    var isPlaying: Bool {
        playbackTask != nil
    }

    /// Whether the preview currently has a soundtrack rolling.
    var isPreviewAudioPlaying: Bool {
        previewAudio.isPlaying
    }

    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            play()
        }
    }

    func play() {
        guard !isPlaying, edit.duration > 0 else { return }
        // Playing from the end means playing from the start. Anything else leaves the user
        // pressing a play button that visibly does nothing.
        if playhead >= edit.duration - 0.05 {
            playhead = 0
        }

        // Derived from a clock rather than accumulated per tick, so a slow frame costs a
        // dropped frame and not a drifting playhead — the difference between playback that
        // is a moment behind and playback whose timing cannot be trusted, which for judging
        // a cut is the whole point.
        let from = playhead
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let origin = ContinuousClock.now
            Task { @MainActor [weak self] in
                guard let self else { return }
                await previewAudio.start(from: from, session: session, edit: edit)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.playbackTick)
                guard !Task.isCancelled else { return }
                let elapsed = ContinuousClock.now - origin
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                let next = from + seconds
                guard next < edit.duration else {
                    playhead = edit.duration
                    pausePlayback()
                    return
                }
                playhead = next
                previewAudio.resync(to: next)
            }
        }
    }

    func pausePlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        previewAudio.pause()
    }

    /// Releases the audio decoder. Closing the window has to call this; pausing alone
    /// leaves an `AVPlayer` item sitting on a composition.
    func stopPlayback() {
        pausePlayback()
        previewAudio.stop()
    }

    /// How often the playhead is moved while playing.
    ///
    /// Thirty a second, not sixty: every tick costs a decode and a compose, and past the
    /// rate the renderer can actually sustain the extra ticks only cancel each other. The
    /// clock is what keeps time — this is just how often it is read.
    static var playbackTick: Duration {
        .milliseconds(33)
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
