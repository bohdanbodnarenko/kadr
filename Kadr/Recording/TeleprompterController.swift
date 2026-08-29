import AppKit
import Foundation
import os
import SettingsKit
import Shared
import StudioCore

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

        link = DisplayLinkDriver { [weak self] in self?.tick() }
        link?.start()
        startFollowingIfWanted(script: script)
        logger.info("Teleprompter started")
    }

    func stop() {
        guard panel != nil else { return }
        saveFrame()
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
            let pacing = TeleprompterPacing(wordsPerMinute: settings.teleprompterWordsPerMinute)
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
