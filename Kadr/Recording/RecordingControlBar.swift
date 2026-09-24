import AppKit
import CoreGraphics
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// The floating controls shown before and during a recording (docs/03 §1.8, docs/08 §2).
///
/// One panel, one bar, three modes. The picker, the countdown strip and the live Stop/Pause
/// controls are the same glass bar with different contents, so Record morphs the picker into
/// the countdown and the countdown into the clock — the bar's rounded rect springs to the new
/// width while the controls cross-fade. Area/Window only hide it while the selection overlay
/// owns the screen.
///
/// The panel is a fixed size that every mode sits inside, so an update never resizes the
/// window: resizing on each timer tick is what made the bar jitter and ghost. The transparent
/// slack around the bar holds tooltips and the glass shadow; the hosting view hit-tests only
/// the bar so that slack never swallows clicks meant for what is being recorded.
///
/// A non-activating panel, for the same reason the scrolling-capture HUD is one: the user
/// is recording whatever is behind this, and a bar that stole focus would change the thing
/// being filmed. It registers with `CaptureExclusionRegistry`, so it never appears in the
/// recording it controls.
///
/// Live session chrome is either this floating island or a Dynamic Island-style strip on a
/// MacBook camera notch, chosen in Recording settings. Destroyed when idle — no window, no
/// view, no timer (PRD §8).
@MainActor
final class RecordingControlBar {
    private var panel: NonActivatingPanel?
    private var hosting: RecordingBarHostingView?
    private let model = RecordingControlBarModel()
    private var hideTask: Task<Void, Never>?
    /// What the current window was built for. Notch and island panels differ in level,
    /// size and movability, so switching between them needs a new window.
    private var panelDocksToNotch = false

    /// Where the user last dragged the floating island, so it comes back where they put it.
    ///
    /// Screen-relative and re-clamped on show: a bar remembered on a display that has since
    /// been unplugged has to come back somewhere visible rather than off the desk.
    static var savedOrigin: CGPoint?

    /// Set only while a hand-off from the All-in-One island creates the panel.
    private var entranceOrigin: CGPoint?

    /// Distance from the bottom of the visible frame to the bar (not the panel).
    private static let bottomInset: CGFloat = 48
    private static let edgeMargin: CGFloat = 12
    /// Used to keep the bar on screen before SwiftUI has measured it.
    private static let estimatedBarWidth: CGFloat = 560

    static var panelSize: CGSize {
        CGSize(width: RecordingBarMetrics.panelWidth, height: RecordingBarMetrics.panelHeight)
    }

    var isShowing: Bool {
        panel != nil
    }

    /// The visible bar in screen space, so the teleprompter composer can sit next to it —
    /// not the padded panel, or satellites would float clear of the bar.
    var screenFrame: NSRect? {
        guard let panel else { return nil }
        let bar = model.barFrameInPanel
        guard bar != .zero else { return panel.frame }
        // SwiftUI reports a top-left origin; screen coordinates are bottom-up.
        return NSRect(
            x: panel.frame.minX + bar.minX,
            y: panel.frame.maxY - bar.maxY,
            width: bar.width,
            height: bar.height
        )
    }

    var isShowingPicker: Bool {
        panel != nil && model.mode == .picker
    }

    /// Notch layout is only for a live take (or its countdown) on a notched display.
    static func shouldDockToNotch(
        chrome: RecordingControlChrome,
        screenHasNotch: Bool,
        isLiveSession: Bool
    ) -> Bool {
        chrome == .notch && screenHasNotch && isLiveSession
    }

    /// - Parameter source: the All-in-One island's glass in screen space, when Record was
    ///   picked there. The bar opens on top of it at its size and morphs into itself.
    func showPicker(model picker: RecordSetupModel, morphingFrom source: NSRect? = nil) {
        hideTask?.cancel()
        hideTask = nil
        if panel != nil, panelDocksToNotch {
            teardownPanel()
        }
        model.chrome = picker.settings.recordingControlChrome
        model.docksToNotch = false
        model.notchVisible = false
        model.notchExpanded = false
        let morphs = panel == nil && source != nil && !AccessibilityChrome.reduceMotion
        if morphs, let source {
            model.entranceSize = source.size
            entranceOrigin = Self.panelOrigin(barBottomCentre: CGPoint(x: source.midX, y: source.minY))
        }
        setContents(picker: picker, session: nil, preRoll: nil, settings: nil)
        present(key: true)
        entranceOrigin = nil
        if morphs {
            finishEntrance()
        }
    }

    /// Where a panel goes so its bar's bottom edge is centred on `point`.
    static func panelOrigin(barBottomCentre point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - panelSize.width / 2,
            y: point.y - RecordingBarMetrics.shadowSlack
        )
    }

    /// The second half of the hand-off: the glass springs to the picker's width, and the
    /// window glides to where the recording bar lives if that is somewhere else.
    private func finishEntrance() {
        // A turn later, so the first frame is drawn at the island's size to spring from.
        Task { @MainActor [weak self] in
            guard let self, let panel else { return }
            withAnimation(RecordingBarMetrics.modeChange) {
                model.entranceSize = nil
            }
            let destination = floatingFrame()
            guard !panel.frame.equalTo(destination) else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(destination, display: true)
            }
        }
    }

    /// - Parameter fading: fade the bar out first, for a hand-back to the capture island
    ///   that fades in on the same spot.
    func dismissPicker(fading: Bool = false) {
        guard isShowingPicker else { return }
        guard fading, !AccessibilityChrome.reduceMotion, let panel else {
            dismiss()
            return
        }
        hideTask?.cancel()
        RecordingBarHoverView.endActiveHover()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.handBackFade
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        // Torn down once the fade is over; `showPicker` cancels this if the recorder is
        // asked for again first, and `present` restores the alpha.
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.handBackFade + 0.03))
            guard !Task.isCancelled else { return }
            self?.teardownPanel()
        }
    }

    private static let handBackFade: TimeInterval = 0.16

    func show(controls: RecordingControls, settings: AppSettings? = nil, preRoll: PreRoll? = nil) {
        hideTask?.cancel()
        hideTask = nil
        if panel != nil, panelDocksToNotch != docksToNotch(settings: settings) {
            teardownPanel()
        }
        model.apply(controls)
        applyChrome(settings: settings)
        setContents(picker: nil, session: true, preRoll: preRoll, settings: settings)
        present(key: false)
    }

    /// Updates the timer and the mode without rebuilding or resizing anything.
    ///
    /// When the picker is still up this is the handoff: the same bar morphs into the
    /// countdown, then into the clock.
    func update(controls: RecordingControls, settings: AppSettings? = nil, preRoll: PreRoll? = nil) {
        guard panel != nil else { return }
        guard panelDocksToNotch == docksToNotch(settings: settings) else {
            show(controls: controls, settings: settings, preRoll: preRoll)
            return
        }
        model.apply(controls)
        applyChrome(settings: settings)
        setContents(picker: nil, session: true, preRoll: preRoll, settings: settings)
    }

    /// Moves the level meter, and nothing else (PRD §8).
    ///
    /// The recording tick calls this ten times a second. It touches one observable that one
    /// small view reads, rather than going through `update`, which re-resolves the chrome.
    func setAudioLevel(_ level: Float) {
        guard panel != nil else { return }
        model.meter.set(level)
    }

    /// What the bar offers while the countdown is running.
    ///
    /// The three things a recording is usually got wrong by forgetting — microphone, system
    /// sound, camera — were reachable only from Settings, so recording a demo with your
    /// voice meant leaving the thing you were about to record, opening a window, finding a
    /// checkbox and coming back. docs/03 §1.8 asks for a control strip before Record for
    /// exactly this.
    struct PreRoll {
        let remaining: Int
        let startNow: () -> Void
        let cancel: () -> Void
    }

    func dismiss() {
        hideTask?.cancel()
        if panelDocksToNotch, panel != nil {
            // Shrink back into the notch in two beats — the row, then the ears — and only
            // then take the window away, so it never vanishes mid-spring (macos-notch-ui).
            RecordingBarHoverView.endActiveHover()
            model.notchExpanded = false
            model.confirmation = nil
            model.preRoll = nil
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                model.notchVisible = false
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                teardownPanel()
            }
            return
        }
        teardownPanel()
    }

    /// Keeps the bar — not the transparent panel around it — on the visible frame.
    static func clampedOrigin(
        _ origin: CGPoint,
        barWidth: CGFloat,
        in visible: CGRect
    ) -> CGPoint {
        let size = panelSize
        let halfBar = barWidth / 2 + edgeMargin
        let midX = min(
            max(origin.x + size.width / 2, visible.minX + halfBar),
            visible.maxX - halfBar
        )
        let slack = RecordingBarMetrics.shadowSlack
        let minY = visible.minY + edgeMargin - slack
        let maxY = visible.maxY - edgeMargin - slack - RecordingBarMetrics.barHeight
        return CGPoint(x: midX - size.width / 2, y: min(max(origin.y, minY), maxY))
    }

    /// Bottom-centre of the visible frame, with the bar `bottomInset` above it.
    static func defaultOrigin(in visible: CGRect) -> CGPoint {
        CGPoint(
            x: visible.midX - panelSize.width / 2,
            y: visible.minY + bottomInset - RecordingBarMetrics.shadowSlack
        )
    }

    // MARK: - Contents

    /// Assigns what the bar shows, animating only when that changes its mode.
    ///
    /// The clock ticks through here too; springing every tick would animate the digits
    /// and the meter, so an unchanged mode is assigned plainly.
    private func setContents(
        picker: RecordSetupModel?,
        session: Bool?,
        preRoll: PreRoll?,
        settings: AppSettings?
    ) {
        let next = RecordingControlBarModel.mode(
            hasPicker: picker != nil,
            hasSession: session != nil,
            hasPreRoll: preRoll != nil && settings != nil
        )
        let morphs = panel?.isVisible == true && !model.docksToNotch && next != model.mode
        let apply = {
            self.model.picker = picker
            self.model.session = session
            self.model.preRoll = preRoll
            self.model.settings = settings
        }
        if morphs {
            RecordingBarHoverView.endActiveHover()
            withAnimation(AccessibilityChrome.animation(RecordingBarMetrics.modeChange), apply)
        } else {
            apply()
        }
    }

    private func docksToNotch(settings: AppSettings?) -> Bool {
        Self.shouldDockToNotch(
            chrome: settings?.recordingControlChrome ?? .island,
            screenHasNotch: RecordingNotchScreen.isAvailable,
            isLiveSession: true
        )
    }

    private func applyChrome(settings: AppSettings?) {
        model.chrome = settings?.recordingControlChrome ?? .island
        model.docksToNotch = docksToNotch(settings: settings)
        if model.docksToNotch {
            model.notchMetrics = RecordingNotchScreen.metrics
        }
    }

    // MARK: - Window

    /// Brings the bar forward and hands the keyboard to the view inside it.
    ///
    /// The `makeFirstResponder` is the half that is easy to miss: a key window whose
    /// content view is not the first responder answers no keys at all, which is why the
    /// recorder's Esc and its letters did nothing while its buttons worked.
    private func takeKeyboard(_ panel: NSPanel) {
        panel.makeKeyAndOrderFront(nil)
        if let content = panel.contentView {
            panel.makeFirstResponder(content)
        }
    }

    private func present(key: Bool) {
        if let panel {
            panel.alphaValue = 1
            panel.becomesKeyOnlyIfNeeded = !key
            if key {
                takeKeyboard(panel)
            } else {
                panel.orderFrontRegardless()
            }
            if panelDocksToNotch {
                placeNotchPanel()
            }
            revealNotchIfNeeded()
            return
        }

        let frame = if model.docksToNotch {
            notchFrame(on: RecordingNotchScreen.notchScreen ?? NSScreen.main)
        } else if let entranceOrigin {
            NSRect(origin: entranceOrigin, size: Self.panelSize)
        } else {
            floatingFrame()
        }
        let hosting = RecordingBarHostingView(rootView: RecordingControlBarView(model: model))
        configureHosting(hosting)
        hosting.frame = NSRect(origin: .zero, size: frame.size)

        let panel = NonActivatingPanel(contentRect: hosting.frame, level: windowLevel)
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        // The controls track hover themselves so they still highlight while Kadr is in
        // the background — which is the whole time a recording runs.
        panel.acceptsMouseMovedEvents = true
        // Nothing in the bar wants a cursor but the hand its controls push; AppKit's
        // cursor rects would reset it to an arrow on every move while Kadr is active.
        panel.disableCursorRects()
        let movable = !model.docksToNotch
        panel.isMovable = movable
        panel.isMovableByWindowBackground = movable
        panel.becomesKeyOnlyIfNeeded = !key
        CaptureExclusionRegistry.shared.register(panel)
        if key {
            takeKeyboard(panel)
        } else {
            panel.orderFrontRegardless()
        }
        self.panel = panel
        self.hosting = hosting
        panelDocksToNotch = model.docksToNotch
        revealNotchIfNeeded()
    }

    private func configureHosting(_ hosting: RecordingBarHostingView) {
        // The panel is sized explicitly and the bar animates its own width inside it. Left
        // to bridge its ideal size onto the window, the two fight over sizing every frame.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.masksToBounds = model.docksToNotch
        // A docked island sits in the menu-bar strip. Container safe area would
        // inset it and leave a hairline under the hardware notch.
        hosting.safeAreaRegions = model.docksToNotch ? [] : .all
        // The notch is always black, whatever the system appearance: dynamic colours
        // (label, separator, tooltip glass) must resolve for a dark surface.
        hosting.appearance = model.docksToNotch ? NSAppearance(named: .darkAqua) : nil
    }

    private func teardownPanel() {
        hideTask = nil
        guard let panel else { return }
        RecordingBarHoverView.endActiveHover()
        if !panelDocksToNotch {
            Self.savedOrigin = panel.frame.origin
        }
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        hosting = nil
        panelDocksToNotch = false
        model.picker = nil
        model.session = nil
        model.preRoll = nil
        model.barFrameInPanel = .zero
        model.entranceSize = nil
        model.docksToNotch = false
        model.notchVisible = false
        model.notchExpanded = false
        model.confirmation = nil
    }

    private func revealNotchIfNeeded() {
        guard model.docksToNotch else {
            model.notchVisible = false
            return
        }
        Task { @MainActor in
            model.notchVisible = true
        }
    }

    /// The notch shell sits just above the menu bar it grows out of. Not the shielding
    /// level: that also covers system alerts, permission sheets and Kadr's own overlays.
    private var windowLevel: NSWindow.Level {
        model.docksToNotch
            ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            : .floating
    }

    private func floatingFrame() -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = Self.savedOrigin ?? Self.defaultOrigin(in: visible)
        let barWidth = model.barFrameInPanel.width > 0 ? model.barFrameInPanel.width : Self.estimatedBarWidth
        return NSRect(
            origin: Self.clampedOrigin(origin, barWidth: barWidth, in: visible),
            size: Self.panelSize
        )
    }

    private func placeNotchPanel() {
        guard let panel, let hosting else { return }
        let frame = notchFrame(on: RecordingNotchScreen.notchScreen ?? NSScreen.main)
        // Re-setting the frame while the island is springing leaves a delayed ghost.
        guard !panel.frame.equalTo(frame) else { return }
        panel.setFrame(frame, display: false)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func notchFrame(on screen: NSScreen?) -> NSRect {
        let size = model.notchLayout.windowSize
        guard let screen else {
            return NSRect(origin: .zero, size: size)
        }
        // `frame`, not `visibleFrame`: the notch lives in the menu-bar strip.
        let x = screen.frame.origin.x + (screen.frame.width - size.width) / 2
        let y = screen.frame.origin.y + screen.frame.height - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// The panel is much larger than the bar. AppKit hit-tests by bounds, not alpha, so without
/// this the transparent slack would swallow clicks meant for whatever is behind it.
final class RecordingBarHostingView: NSHostingView<RecordingControlBarView> {
    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The floating bar or the notch shell — whichever is showing reports its frame.
        let bar = rootView.model.barFrameInPanel
        // SwiftUI reports a top-left origin and NSHostingView is flipped, so they agree.
        guard bar != .zero, bar.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}
