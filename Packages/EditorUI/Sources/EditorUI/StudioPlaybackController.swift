import AVFoundation
import CoreGraphics
import Foundation
import Observation
import os
import Shared
import StudioRender
import StudioSession

/// The studio preview's player and its only clock (docs/08 §2 item 10, docs/09 U3.3).
///
/// One `AVPlayer` over the edit's clip composition, with `StudioVideoCompositor` drawing
/// every frame through the export's own `StudioFrameComposer`. That replaces three things
/// that each cost more than they bought: a seeking image generator per frame, a GPU
/// readback per frame into a SwiftUI `Image`, and a second `AVPlayer` for the sound that
/// had to be dragged back into line with a sleeping task. Audio and picture now share one
/// clock by construction, and the player drops late frames itself.
///
/// The ways this stays cheap:
/// - **Builds never run on the main actor.** The render plan and the composer are built in
///   a detached task, one at a time, latest-wins (`StudioLatestWins`); the last picture stays
///   up until the next one is ready.
/// - **A picture change keeps the item.** Only a new cut, soundtrack or camera track
///   replaces the `AVPlayerItem`; everything else swaps its `videoComposition`
///   (`StudioPlaybackRebuild`).
/// - **Scrubbing chases.** One zero-tolerance seek at a time, then on to the latest target
///   (`StudioSeekChase`).
/// - **Idle is idle.** Paused with nothing changing there is no timer, no task and no time
///   observer: the observer exists only while the player is rolling.
/// - **Closing releases everything.** `stop()` drops the item, the player and every task,
///   so a closed window holds no decoder.
@MainActor
@Observable
final class StudioPlaybackController {
    /// What the preview layer shows. Nil until a composition is ready, and again after
    /// `stop()`.
    private(set) var player: AVPlayer?

    /// The pixel size of the picture on screen, once one has been built.
    private(set) var outputSize: CGSize?

    /// The timeline hover thumbnail, or nil when nothing is being hovered.
    var skimImage: CGImage?

    @ObservationIgnored private(set) weak var model: StudioDocumentModel?
    @ObservationIgnored private var longestEdge = StudioPreviewSize.fallbackLongestEdge

    // MARK: Building

    @ObservationIgnored private var builds = StudioLatestWins<StudioPreviewRequest>()
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private(set) var reuse = StudioPreviewPipeline.Reuse()
    /// Bumped by `stop()`, so a build that finishes afterwards installs nothing.
    @ObservationIgnored private var lifetime = 0

    /// What is on screen: the request, and the immutable composition the item plays.
    @ObservationIgnored private(set) var installed: StudioPreviewRequest?
    @ObservationIgnored private(set) var composition: AVComposition?

    // MARK: Clock

    @ObservationIgnored private var chase = StudioSeekChase()
    /// Bumped whenever a seek in flight stops mattering — a new item, a play, a stop.
    @ObservationIgnored private var seekEpoch = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    /// The playhead value this controller last wrote, so the preview can tell its own
    /// clock ticking from somebody dragging the playhead.
    @ObservationIgnored private var reportedPlayhead: TimeInterval?

    // MARK: Skimming

    /// See `StudioPlaybackController+Skim.swift`.
    @ObservationIgnored var skimTask: Task<Void, Never>?
    @ObservationIgnored var skimBuild: (request: StudioPreviewRequest, task: Task<StudioPreviewPipeline, Never>)?
    @ObservationIgnored var skimGenerator: StudioPlaybackSkimGenerator?

    private static let signposter = KadrLog.signposter(.app)

    /// How often the playhead follows the player while it rolls. Thirty a second is what
    /// the timeline and the clock can show; the picture itself runs at the player's rate.
    static let playheadInterval = CMTime(value: 1, timescale: 30)

    init() {}

    /// Binds the controller to the model it plays. Idempotent.
    func attach(_ model: StudioDocumentModel) {
        guard self.model !== model else { return }
        self.model = model
    }

    // MARK: - Requests

    /// Brings the picture up to date with the model's edit.
    ///
    /// Called for every edit, crop-mode and transcript change. Cheap when nothing changed.
    func update() {
        guard let model else { return }
        let request = StudioPreviewRequest(
            edit: model.edit,
            transcript: model.transcript,
            longestEdge: longestEdge,
            isCropping: model.isCropping,
            isAimingZoom: model.isAimingZoom
        )
        if builds.isIdle, request == installed {
            return
        }
        if let next = builds.submit(request) {
            startBuild(next)
        }
    }

    /// Whether a build is running or waiting. Tests wait on it; nothing else needs to.
    var isBuilding: Bool {
        !builds.isIdle
    }

    /// Records the preview's size in pixels, bucketed, and rebuilds if the bucket moved.
    func setViewSize(_ size: CGSize, backingScale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        let bucket = StudioPreviewSize.bucket(for: size, backingScale: backingScale)
        guard bucket != longestEdge else { return }
        longestEdge = bucket
        update()
    }

    private func startBuild(_ request: StudioPreviewRequest) {
        guard let model else {
            builds.reset()
            return
        }
        let inputs = StudioPreviewPipeline.Inputs(
            request: request,
            session: model.session,
            manifest: model.manifest,
            telemetry: model.telemetry,
            reuse: reuse
        )
        // Serial builds make this exact: whatever is installed when this one finishes is
        // what is installed now.
        let rebuildsTimeline = StudioPlaybackRebuild.between(installed, request) == .timeline
        let session = model.session
        let cameraStartOffset = model.manifest.cameraStartOffset
        let token = lifetime

        buildTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                StudioPreviewPipeline.build(inputs)
            }.value
            let composition: AVMutableComposition? = if rebuildsTimeline {
                await Self.makeComposition(
                    for: request.edit,
                    session: session,
                    cameraStartOffset: cameraStartOffset
                )
            } else {
                nil
            }
            guard let self, token == lifetime, !Task.isCancelled else { return }
            reuse = built.reuse
            install(request, pipeline: built.pipeline, composition: composition, rebuildsTimeline: rebuildsTimeline)
            if let next = builds.finish() {
                startBuild(next)
            } else {
                buildTask = nil
            }
        }
    }

    /// The edit's clips as a playable composition, or nil if the footage will not open.
    ///
    /// Nonisolated so the file loading happens off the main actor.
    private nonisolated static func makeComposition(
        for edit: StudioEdit,
        session: RecordingSession,
        cameraStartOffset: TimeInterval
    ) async -> sending AVMutableComposition? {
        try? await ClipCompositionBuilder().composition(
            for: edit.clips,
            screen: session.screenURL,
            // The track exists only while the bubble is shown: a hidden camera is a decoder
            // doing nothing.
            camera: edit.camera.isVisible ? session.cameraURL : nil,
            cameraStartOffset: cameraStartOffset,
            soundtrack: session.soundtrackURL(for: edit),
            includeAudio: !edit.mutesAudio
        )
    }

    private func install(
        _ request: StudioPreviewRequest,
        pipeline: StudioPreviewPipeline,
        composition built: AVMutableComposition?,
        rebuildsTimeline: Bool
    ) {
        guard let model else { return }
        installed = request
        outputSize = pipeline.plan.outputSize
        let frameRate = model.manifest.frameRate

        guard rebuildsTimeline else {
            // Same cut, new picture: the item keeps its decoder and its place.
            guard let item = player?.currentItem, let composition,
                  let video = StudioVideoComposition.make(
                      for: composition,
                      composer: pipeline.composer,
                      frameRate: frameRate
                  )
            else { return }
            item.videoComposition = video
            if !model.isPlaying {
                // A paused player does not recompose on its own; a seek to where it already
                // is makes it draw the frame again with the new composer.
                seek(to: model.playhead)
            }
            return
        }

        // An immutable copy, so the item and the skim generator can share it across
        // AVFoundation's threads.
        guard let copy = built?.copy() as? AVComposition,
              let video = StudioVideoComposition.make(
                  for: copy,
                  composer: pipeline.composer,
                  frameRate: frameRate
              )
        else {
            // Nothing that will play. Saying "playing" over a black well would be a lie.
            clearItem()
            if model.isPlaying {
                pause()
            }
            return
        }
        let item = AVPlayerItem(asset: copy)
        item.videoComposition = video
        let player = player ?? makePlayer()
        removeObservers()
        seekEpoch += 1
        chase.reset()
        player.replaceCurrentItem(with: item)
        composition = copy
        skimGenerator = nil

        if model.isPlaying {
            startRolling()
        } else {
            seek(to: model.playhead)
        }
    }

    private func makePlayer() -> AVPlayer {
        let player = AVPlayer()
        player.actionAtItemEnd = .pause
        // Local files: there is nothing to buffer, and waiting to "minimise stalling" only
        // delays the first frame.
        player.automaticallyWaitsToMinimizeStalling = false
        // No AirPlay route. Nothing the user records leaves the Mac (CLAUDE.md rule 1).
        player.allowsExternalPlayback = false
        self.player = player
        return player
    }

    private func clearItem() {
        removeObservers()
        seekEpoch += 1
        chase.reset()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        composition = nil
        skimGenerator = nil
    }

    // MARK: - Transport

    /// Whether sound is coming out: the player is rolling over a composition with audio.
    var isAudible: Bool {
        guard let player, player.rate > 0, let composition else { return false }
        return !composition.tracks(withMediaType: .audio).isEmpty
    }

    func play() {
        guard let model, !model.isPlaying, model.edit.duration > 0 else { return }
        // Playing from the end means playing from the start. Anything else leaves the user
        // pressing a play button that visibly does nothing.
        if model.playhead >= model.edit.duration - 0.05 {
            model.playhead = 0
        }
        model.isPlaying = true
        skim(at: nil)
        update()
        startRolling()
    }

    /// Starts the player from the playhead, if there is an item to play. Called again when
    /// one arrives.
    private func startRolling() {
        guard let model, model.isPlaying, let player, let item = player.currentItem else { return }
        let target = model.playhead
        let frame = 0.5 / Double(max(model.manifest.frameRate, 1))
        if abs(player.currentTime().seconds - target) > frame {
            // Whatever a scrub was chasing is overtaken by playing from here.
            seekEpoch += 1
            chase.reset()
            player.seek(to: Self.time(target), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        reportedPlayhead = target
        removeObservers()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: Self.playheadInterval,
            // The main queue, which is where the playhead lives — not a queue of our own.
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.follow(time)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reachedEnd()
            }
        }
        player.play()
    }

    func pause() {
        guard let model else { return }
        removeObservers()
        if let player, player.rate != 0 {
            player.pause()
        }
        if model.isPlaying, let player, player.currentItem != nil {
            // Leave the playhead on the frame that is showing, not one tick behind it.
            let now = player.currentTime().seconds
            if now.isFinite {
                report(now)
            }
        }
        model.isPlaying = false
    }

    /// Releases the player, the item, every build and every observer.
    ///
    /// Closing the window calls this: a paused player still holds its item's decoder, and a
    /// build that finishes after the window has gone would put one back.
    func stop() {
        lifetime += 1
        buildTask?.cancel()
        buildTask = nil
        builds.reset()
        skim(at: nil)
        skimBuild = nil
        clearItem()
        player = nil
        installed = nil
        outputSize = nil
        reuse = StudioPreviewPipeline.Reuse()
        reportedPlayhead = nil
        model?.isPlaying = false
    }

    private func follow(_ time: CMTime) {
        guard let model, model.isPlaying else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        report(seconds)
    }

    private func reachedEnd() {
        guard let model, model.isPlaying else { return }
        removeObservers()
        player?.pause()
        report(model.edit.duration)
        model.isPlaying = false
    }

    private func report(_ seconds: TimeInterval) {
        guard let model else { return }
        model.playhead = seconds
        reportedPlayhead = model.playhead
    }

    private func removeObservers() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    // MARK: - Scrubbing

    /// The playhead moved. Seeks unless the move was this controller's own clock.
    func playheadDidChange(to time: TimeInterval) {
        if let reportedPlayhead, abs(reportedPlayhead - time) < 1e-9 {
            return
        }
        reportedPlayhead = nil
        seek(to: time)
    }

    private func seek(to time: TimeInterval) {
        guard player?.currentItem != nil else { return }
        guard let target = chase.request(time) else { return }
        issueSeek(to: target)
    }

    private func issueSeek(to target: TimeInterval) {
        guard let player, player.currentItem != nil else {
            chase.reset()
            return
        }
        let epoch = seekEpoch
        let interval = Self.signposter.beginInterval("studio.preview.seek")
        player.seek(
            to: Self.time(target),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [self] in
                Self.signposter.endInterval("studio.preview.seek", interval)
                self?.seekLanded(epoch: epoch)
            }
        }
    }

    private func seekLanded(epoch: Int) {
        guard epoch == seekEpoch else { return }
        if let next = chase.completed() {
            issueSeek(to: next)
        }
    }

    static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
    }
}
