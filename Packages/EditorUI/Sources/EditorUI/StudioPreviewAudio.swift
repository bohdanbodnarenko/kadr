import AVFoundation
import Foundation
import StudioRender
import StudioSession

/// The soundtrack that plays with the studio preview.
///
/// The picture is still composed one frame at a time so preview equals export. Audio has
/// no equivalent of that: it has to come off the same clip composition the export uses, or
/// a cut, a speed change, or an imported soundtrack can only be judged after a render.
/// `AVPlayer` over an audio-only copy of that composition is the smallest way to hear the
/// same timeline the writer will mux.
@MainActor
final class StudioPreviewAudio {
    private let player = AVPlayer()
    private var prepared: Prepared?
    /// Bumped on every start/stop so a prepare that outlives a pause cannot start playing.
    private var generation = 0

    private struct Prepared: Equatable {
        var screenPath: String
        var clips: ClipTimeline
        var soundtrackPath: String?
    }

    var isPlaying: Bool {
        player.rate > 0
    }

    var hasItem: Bool {
        player.currentItem != nil
    }

    init() {
        player.actionAtItemEnd = .pause
    }

    /// Starts the soundtrack at `time`, rebuilding the composition only when the cut or
    /// the imported file has changed.
    func start(from time: TimeInterval, session: RecordingSession, edit: StudioEdit) async {
        generation += 1
        let token = generation
        await prepare(session: session, edit: edit)
        guard token == generation else { return }
        seek(to: time)
        guard hasItem else { return }
        player.play()
    }

    func pause() {
        generation += 1
        player.pause()
    }

    /// Stops decoding. Closing the window has to call this: an `AVPlayer` left with an
    /// item keeps a decoder alive after the preview has gone.
    func stop() {
        generation += 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        prepared = nil
    }

    /// Pulls the player back onto `time` if it has drifted from the picture clock.
    ///
    /// The playhead is driven by a `ContinuousClock` so dropped frames do not accumulate.
    /// The player is a second clock. Seeking every tick would stutter; seeking only when
    /// they have actually parted keeps them together without fighting over every sample.
    func resync(to time: TimeInterval) {
        guard player.rate > 0 else { return }
        let current = CMTimeGetSeconds(player.currentTime())
        guard current.isFinite, abs(current - time) > 0.12 else { return }
        seek(to: time)
    }

    private func seek(to time: TimeInterval) {
        guard hasItem else { return }
        let stamp = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        player.seek(to: stamp, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func prepare(session: RecordingSession, edit: StudioEdit) async {
        let next = Prepared(
            screenPath: session.screenURL.path,
            clips: edit.clips,
            soundtrackPath: session.soundtrackURL(for: edit)?.path
        )
        if prepared == next, hasItem {
            return
        }

        prepared = next
        guard let audio = await Self.audioComposition(session: session, edit: edit) else {
            player.replaceCurrentItem(with: nil)
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(asset: audio))
        await waitUntilReady()
    }

    private func waitUntilReady() async {
        guard let item = player.currentItem else { return }
        for _ in 0 ..< 40 {
            if item.status == .readyToPlay {
                return
            }
            if item.status == .failed {
                player.replaceCurrentItem(with: nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The edited soundtrack with no picture, so the preview does not decode the movie twice.
    private static func audioComposition(
        session: RecordingSession,
        edit: StudioEdit
    ) async -> AVMutableComposition? {
        let mixed: AVMutableComposition
        do {
            mixed = try await ClipCompositionBuilder().composition(
                for: edit.clips,
                screen: session.screenURL,
                soundtrack: session.soundtrackURL(for: edit)
            )
        } catch {
            return nil
        }
        let sources = mixed.tracks(withMediaType: .audio)
        guard !sources.isEmpty else { return nil }

        let audio = AVMutableComposition()
        for source in sources {
            guard let track = audio.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try? track.insertTimeRange(source.timeRange, of: source, at: source.timeRange.start)
        }
        return audio.tracks(withMediaType: .audio).isEmpty ? nil : audio
    }
}
