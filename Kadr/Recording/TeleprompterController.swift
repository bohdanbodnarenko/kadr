import AppKit
import Foundation
import os
import SettingsKit
import Shared
import StudioSession

/// Runs the prompter alongside a recording (docs/08, teleprompter).
///
/// It exists only while a recording does. The panel, its timer and — if the user asked for
/// it — the speech recogniser are all built when recording starts and torn down when it
/// stops, so the idle agent is exactly as it was before this feature existed (PRD §8).
///
/// Scrolling is driven by a display link rather than a repeating timer. The panel is
/// animating text under somebody's eyes while a recording runs; a timer that fires on a
/// schedule of its own beats against the display's refresh and shows up as judder, which is
/// the one visual defect a prompter cannot have.
@MainActor
final class TeleprompterController {
    private let logger = KadrLog.logger(.recording)
    private let settings: AppSettings

    private var panel: TeleprompterPanel?
    private var link: DisplayLinkDriver?
    private var follower: LiveSpeechFollower?
    /// The pace and look, read when they change rather than on every frame.
    ///
    /// `@Observable` charges a registrar lookup for each property read, and the scroll
    /// reads these at the display's refresh rate for the length of a recording. Cached and
    /// re-read on change, that becomes a handful of reads per session.
    private var pacing = TeleprompterPacing()
    private var settingsObservation: SettingsObservation?

    /// Where the reader is, in words. Fractional so the scroll is continuous.
    private var position: Double = 0
    /// When the current run of scrolling began, and where it began from.
    private var startedAt: Date?
    private var startedFrom: Double = 0
    private var isPaused = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isShowing: Bool {
        panel != nil
    }

    // MARK: - Lifecycle

    /// Puts the prompter up, if the user has one to read.
    ///
    /// Silent when the script is empty rather than showing an empty panel: somebody who
    /// left the setting on and the script blank wants nothing on screen, not a reminder.
    func start() {
        guard settings.teleprompterEnabled else { return }
        let script = TeleprompterScript(text: settings.teleprompterScript)
        guard !script.isEmpty else {
            logger.info("Teleprompter is on but the script is empty; showing nothing")
            return
        }
        guard panel == nil else { return }

        let panel = TeleprompterPanel(frame: NSRect(x: 0, y: 0, width: 760, height: 220))
        panel.script = script
        panel.style = style
        panel.positionOnScreen(savedFrame)
        panel.orderFrontRegardless()
        self.panel = panel

        position = 0
        startedFrom = 0
        startedAt = Date()
        isPaused = false

        syncFromSettings()
        observeSettings()
        link = DisplayLinkDriver { [weak self] in self?.tick() }
        link?.start()
        startFollowingIfWanted(script: script)
        logger.info("Teleprompter started")
    }

    func stop() {
        guard panel != nil else { return }
        saveFrame()
        settingsObservation?.cancel()
        settingsObservation = nil
        link?.stop()
        link = nil
        follower?.stop()
        follower = nil
        panel?.retire()
        panel?.orderOut(nil)
        panel = nil
        startedAt = nil
        logger.info("Teleprompter stopped")
    }

    /// Holds the script still while the recording is paused.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        startedFrom = position
        startedAt = nil
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        startedAt = Date()
    }

    // MARK: - Scrolling

    private func tick() {
        guard let panel, !isPaused, let startedAt else { return }

        if let follower, let followed = follower.position {
            // Eased rather than jumped. The follower is right about *where* the reader is
            // and wrong about when it noticed, so moving straight there snaps the text
            // under their eyes at the moment they are trying to read it.
            position += (Double(followed) - position) * Self.followEasing
        } else {
            position = startedFrom + pacing.position(after: Date().timeIntervalSince(startedAt))
        }
        panel.position = position
    }

    /// How much of the gap to the followed position to close each frame.
    ///
    /// Low enough that a correction reads as a scroll rather than a jump, high enough that
    /// the script is not visibly lagging behind the voice.
    private static let followEasing: Double = 0.08

    // MARK: - Following

    private func startFollowingIfWanted(script: TeleprompterScript) {
        guard settings.teleprompterFollowsSpeech else { return }
        let follower = LiveSpeechFollower(script: script)
        self.follower = follower
        Task { [weak self] in
            guard await follower.start() else {
                // No permission, no model, no microphone: the prompter falls back to
                // scrolling at the set rate, which is what it would have done anyway.
                await MainActor.run {
                    self?.follower = nil
                    self?.logger.info("Teleprompter is scrolling at a steady rate; speech following is unavailable")
                }
                return
            }
        }
    }

    // MARK: - Settings

    /// Applies the pace and the look, and keeps the scroll continuous across a pace change.
    ///
    /// The elapsed clock is rebased rather than left alone: the position is derived from
    /// how long the reader has been going, so changing the rate mid-recording without
    /// rebasing would recompute the whole scroll at the new rate and jump the script to
    /// wherever that lands.
    private func syncFromSettings() {
        let updated = TeleprompterPacing(wordsPerMinute: settings.teleprompterWordsPerMinute)
        if updated != pacing {
            pacing = updated
            startedFrom = position
            startedAt = isPaused ? nil : Date()
        }
        panel?.style = style
    }

    /// Watches the settings that change what is on screen.
    ///
    /// `withObservationTracking` fires once and has to be re-armed, which is exactly the
    /// shape wanted here: no polling, no per-frame reads, and nothing running once the
    /// prompter is down.
    private func observeSettings() {
        let observation = SettingsObservation()
        settingsObservation = observation
        arm(observation)
    }

    private func arm(_ observation: SettingsObservation) {
        withObservationTracking {
            _ = settings.teleprompterWordsPerMinute
            _ = settings.teleprompterFontSize
            _ = settings.teleprompterMirrored
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, let observation = settingsObservation, !observation.isCancelled else { return }
                syncFromSettings()
                arm(observation)
            }
        }
    }

    private var style: TeleprompterAppearance {
        TeleprompterAppearance(
            fontSize: settings.teleprompterFontSize,
            isMirrored: settings.teleprompterMirrored
        )
    }

    /// Where the panel was left, so it comes back where the reader put it.
    private var savedFrame: NSRect? {
        guard let string = settings.teleprompterFrame, !string.isEmpty else { return nil }
        let rect = NSRectFromString(string)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private func saveFrame() {
        guard let panel else { return }
        settings.teleprompterFrame = NSStringFromRect(panel.frame)
    }
}

/// A live observation of the settings, and a way to stop it.
///
/// `withObservationTracking` cannot be cancelled, so cancellation is a flag the re-arming
/// closure checks: the last callback after the prompter closes finds it set and stops
/// rather than arming another.
@MainActor
final class SettingsObservation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

/// A callback on every display refresh, for as long as it is running.
///
/// `CADisplayLink` rather than a `Timer`, because the panel is animating text under
/// somebody's eyes: a timer at an arbitrary interval beats against the refresh rate and
/// shows as judder. This is also the only repeating anything the agent runs, and it exists
/// solely while a prompter is on screen (PRD §8).
@MainActor
final class DisplayLinkDriver {
    private var link: CADisplayLink?
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
    }

    func start() {
        guard link == nil, let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView else {
            return
        }
        let link = view.displayLink(target: self, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire() {
        onTick()
    }
}
