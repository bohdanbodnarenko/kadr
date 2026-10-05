import AppKit
import AutomationKit
import CaptureCore
import HistoryKit
import MediaExport
import os
import OverlayKit
import SelectionUI
import SettingsKit
import Shared

/// Drives area capture end to end: hotkey → freeze → overlay → crop → clipboard.
///
/// The whole flow is one `Task` tree hung off the initiating command (docs/04 §8), so
/// Esc or a second hotkey cancels everything in flight rather than leaving a freeze
/// half-finished.
@MainActor
final class AreaCaptureCoordinator {
    /// Internal, not private: silent display captures live in
    /// `AreaCaptureCoordinator+Direct.swift`, and `private` is file-scoped.
    let engine: CaptureEngine
    /// Internal, not private: the failure path lives in
    /// `AreaCaptureCoordinator+Delivery.swift`, and `private` is file-scoped.
    let permissions: PermissionCoordinator
    /// Internal, not private: freeze-then-capture lives in `+Direct.swift`.
    let overlay: SelectionOverlayController
    /// Internal, not private: delivery reads the after-capture matrix, and `private` is
    /// file-scoped.
    let settings: AppSettings
    /// Internal, not private: silent display captures live in
    /// `AreaCaptureCoordinator+Direct.swift`, and `private` is file-scoped.
    let timer = CaptureCountdown()
    /// Internal, not private: file OCR lives in `AreaCaptureCoordinator+OCR.swift`.
    let vision = TextRecognizer()
    let recovery = PermissionRecovery()
    /// Internal, not private: the picker path lives in `+Picker.swift`, and `private` is
    /// file-scoped.
    var pickerSession: ContentSharingPickerSession?
    /// Internal, not private: the colour-pick half lives in
    /// `AreaCaptureCoordinator+ColorPick.swift`, and `private` is file-scoped.
    let toast = TextCaptureToast()
    let textReview = TextCaptureReview()
    /// Internal, not private: delivery lives in
    /// `AreaCaptureCoordinator+Delivery.swift`, and `private` is file-scoped.
    let output: CaptureOutput
    /// Internal, not private: the overlay-facing forwarders live in
    /// `AreaCaptureCoordinator+Overlay.swift`, and `private` is file-scoped.
    let quickAccess: QuickAccessManager
    let pins = PinManager()
    /// Internal, not private: silent display captures live in
    /// `AreaCaptureCoordinator+Direct.swift`, and `private` is file-scoped.
    let hygiene: DesktopHygieneController?
    let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    /// Internal, not private: silent display captures live in
    /// `AreaCaptureCoordinator+Direct.swift`, and `private` is file-scoped.
    var inFlight: Task<Void, Never>?

    /// The last committed region, for "capture previous area" (docs/03 §1.1).
    /// Internal: freeze-inspect crops this rect in `+Direct.swift`.
    var lastRegion: (rect: DisplayRect, displayID: CGDirectDisplayID)?

    /// The app that was in front when the hotkey fired.
    ///
    /// Sampled then, not at capture time: by the time the overlay is up the frontmost app
    /// is Kadr, which makes a useless `{app}` in the filename.
    var frontmostAtHotkey: AppIdentity?
    /// Internal, not private: freeze-then-fullscreen lives in `+Direct.swift`.
    var purpose: SelectionPurpose = .capture
    /// The Self-Timer already counted down before the overlay opened, so the selection
    /// must not count down again and throw the freeze away (T-CAP-9).
    var timerAlreadyRan = false
    /// Whether Shift was held when this capture started, which skips auto-beautify
    /// without fighting the overlay's aspect-lock (CleanShot §9).
    var skipAutoBeautify = false

    func rememberBeautifySkip() {
        skipAutoBeautify = NSEvent.modifierFlags.contains(.shift)
    }

    /// Whether the next overlay opens as a colour picker (docs/03 §3 P3, docs/06 M22).
    var startsInEyedropperMode = false

    /// The automation request this capture is serving, if any (docs/03 §8.4).
    ///
    /// Cleared the moment the capture reports, so an automated capture cannot leak its
    /// `action=` into the next one the user takes by hand.
    let automation = AutomationCaptureRequest()

    /// Fired whenever a capture surface appears or goes away, so the menu bar can show
    /// the capture-armed icon (docs/14 UX-08A).
    var onArmedStateChanged: (() -> Void)?

    /// Whether a capture surface is on screen: the selection overlay, or a timer badge.
    var isArmed: Bool {
        overlay.isPresented || timer.isRunning
    }

    init(
        engine: CaptureEngine,
        permissions: PermissionCoordinator,
        settings: AppSettings,
        overlay: SelectionOverlayController = SelectionOverlayController(),
        history: HistoryController? = nil,
        hygiene: DesktopHygieneController? = nil
    ) {
        self.engine = engine
        self.permissions = permissions
        self.settings = settings
        self.overlay = overlay
        self.hygiene = hygiene
        let output = CaptureOutput(settings: settings)
        self.output = output
        quickAccess = QuickAccessManager(settings: settings, output: output, pins: pins, history: history)
        timer.onRunningChanged = { [weak self] _ in
            self?.onArmedStateChanged?()
        }
        // Escape during the wait abandons the capture rather than skipping to it
        // (docs/03 §1.5, docs/14 UX-17A).
        timer.onCancel = { [weak self] in
            guard let self else { return }
            logger.info("Capture countdown cancelled")
            inFlight?.cancel()
            inFlight = nil
            automation.report(.cancelled)
        }
    }

    var hasPreviousRegion: Bool {
        lastRegion != nil
    }

    /// How long this capture waits: the automation's `delay=` if it gave one, otherwise
    /// the user's self-timer (docs/03 §1.5, §8.4).
    var timerSeconds: Int {
        automation.overrides.delaySeconds ?? settings.timerSeconds
    }

    /// Whether to draw the pointer, honouring an automation override (docs/03 §8.4).
    var includesCursor: Bool {
        automation.overrides.includesCursor ?? settings.includesCursor
    }

    /// Arms the next capture with automation's overrides and a place to report to
    /// (docs/03 §8.4).
    func arm(_ overrides: CaptureOverrides, completion: ((CaptureOutcome) -> Void)?) {
        automation.arm(overrides, completion: completion)
    }

    /// Freezes every display and puts the selection overlay up.
    func beginAreaCapture() {
        rememberBeautifySkip()
        beginOverlayCapture(mode: .area)
    }

    /// Countdown first, then the overlay, so hover menus can be staged (docs/03 §1.5).
    ///
    /// Area capture otherwise freezes immediately, which is the right default for a
    /// screenshot but the wrong one for a self-timer: the thing you wanted in the shot
    /// is still being arranged. Uses the configured delay, or 3 seconds when the timer
    /// is off — a dedicated Self-Timer command that waited zero seconds would be a
    /// quieter Capture Area.
    func beginSelfTimedAreaCapture() {
        rememberBeautifySkip()
        let seconds = timerSeconds > 0 ? timerSeconds : SelfTimer.threeSeconds.seconds
        inFlight?.cancel()
        // No region has been chosen yet, so the display under the pointer is the one the
        // user is arranging — `resolveScreen` falls back to it rather than to main.
        timer.run(seconds: seconds, screen: nil, displayID: nil) { [weak self] in
            self?.beginOverlayCapture(mode: .area)
            self?.timerAlreadyRan = true
        }
    }

    /// Freeze to inspect moving UI, then capture from those frames (docs/03 §7).
    func toggleFreezeScreen() {
        if overlay.isPresented {
            cancel()
            return
        }
        beginOverlayCapture(mode: .area, purpose: .inspect)
    }

    /// Freezes every display and opens window-pick mode (docs/03 §1.2).
    func beginWindowCapture() {
        rememberBeautifySkip()
        beginOverlayCapture(mode: .window)
    }

    /// The same selection interaction, tinted, whose result goes to the recogniser
    /// instead of to a file (docs/03 §1.7).
    func beginTextCapture() {
        beginOverlayCapture(mode: .area, purpose: .recognizeText)
    }

    func beginOverlayCapture(
        mode: SelectionMode,
        purpose: SelectionPurpose = .capture,
        frontmost: AppIdentity? = nil
    ) {
        // Freeze inspect is already the area overlay; a second Capture Area must not
        // re-photograph the screen and lose the hover menu (docs/03 §7).
        if overlay.isPresented, self.purpose == .inspect, mode == .area, purpose == .capture {
            return
        }
        guard recovery.allowCapture(permissions: permissions, onPicker: { [weak self] in
            self?.captureWithSystemPicker()
        }) else { return }
        frontmostAtHotkey = frontmost ?? Self.currentFrontmostApp()
        self.purpose = purpose
        // A second hotkey re-freezes rather than stacking overlays (docs/03 §1.1).
        inFlight?.cancel()

        // Opened here so the interval covers the freeze, which is the expensive half of
        // the < 100 ms hotkey-to-overlay budget (PRD §8).
        let interval = signposter.beginInterval("hotkeyToOverlay")
        // Also logged as plain text, so `make perf` can read the PRD §8 budget back from a
        // run with a grant (docs/18 CAP-9).
        let hotkeyAt = ContinuousClock.now

        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                // Applied before the freeze, because an area capture is cropped out of it
                // and has to be in the same range as the file (docs/06 M25).
                await engine.setDynamicRange(settings.captureDynamicRange)
                await CaptureExclusionPush.into(engine)
                // Fetched alongside the freeze rather than after it, and in every mode: W
                // switches an area overlay into window picking, which needs the list too
                // (docs/18 CAP-1, CAP-9). Started before the overlay exists, so it never
                // lists Kadr's own panels.
                let windowFetch = Task { try await Self.pickableWindows(from: engine) }
                let freezes: [DisplayFreeze]
                do {
                    freezes = try await engine.freezeAllDisplays()
                } catch {
                    windowFetch.cancel()
                    throw error
                }
                guard !Task.isCancelled else {
                    // Superseded after the freeze: close the interval rather than leak it.
                    windowFetch.cancel()
                    signposter.endInterval("hotkeyToOverlay", interval)
                    return
                }
                permissions.noteCaptureSuccess()

                // Window mode opens on the list; area mode must not wait for it.
                let windows = await mode == .window ? (try? windowFetch.value) ?? [] : []

                let eyedropper = armOverlay()
                overlay.lastRegion = lastRegion
                overlay.present(
                    freezes: freezes.map { FrozenDisplay(geometry: $0.geometry, image: $0.image) },
                    mode: mode,
                    purpose: purpose,
                    windows: windows,
                    precisionMode: settings.capturePrecisionCrosshair,
                    eyedropper: eyedropper,
                    signpostState: interval
                ) { [weak self] outcome in
                    self?.hygiene?.endCapture()
                    self?.finish(with: outcome, freezes: freezes)
                    self?.onArmedStateChanged?()
                }
                let elapsed = (ContinuousClock.now - hotkeyAt) / .milliseconds(1)
                logger.info("Overlay presented in \(String(format: "%.1f", elapsed), privacy: .public) ms")
                hygiene?.beginCapture()
                onArmedStateChanged?()
                if mode != .window, let windows = try? await windowFetch.value, !Task.isCancelled {
                    overlay.updatePickableWindows(windows)
                }
            } catch {
                signposter.endInterval("hotkeyToOverlay", interval)
                handle(error)
            }
        }
    }

    /// Snapping, aspect lock and eyedropper callbacks, set before the overlay appears.
    private func armOverlay() -> Bool {
        overlay.snapsToEdges = settings.captureSnapsToEdges
        overlay.lockedAspect = settings.captureSelectionAspect.ratio
        overlay.showsCaptureHints = settings.captureShowsOverlayHints
        overlay.confirmsSelection = settings.captureConfirmsSelection
        overlay.onColorPicked = { [weak self] pick in
            self?.deliver(pick)
        }
        overlay.onPrecisionModeChanged = { [weak self] enabled in
            self?.settings.capturePrecisionCrosshair = enabled
        }
        let eyedropper = startsInEyedropperMode
        startsInEyedropperMode = false
        return eyedropper
    }

    /// Repeats the last region with no UI at all (docs/03 §1.1).
    /// Captures a rectangle automation named, with no overlay at all (docs/03 §8.4).
    ///
    /// The rect arrives in AppKit's screen space because that is what a user reads off a
    /// window's frame; it is flipped into CoreGraphics' display space and matched to the
    /// display it lands on here, so nothing downstream has to guess (CLAUDE.md rule 6).
    func captureRegion(_ screenRect: ScreenRect, purpose: SelectionPurpose = .capture) {
        rememberBeautifySkip()
        guard recovery.allowCapture(permissions: permissions, onPicker: { [weak self] in
            self?.captureWithSystemPicker()
        }) else { return }
        inFlight?.cancel()
        frontmostAtHotkey = Self.currentFrontmostApp()
        self.purpose = purpose

        let global = screenRect.inDisplaySpace(.current)
        guard let displayID = DisplayLookup.display(containing: global) else {
            logger.error("The requested region is not on any display")
            automation.report(.failed("That region is not on any display."))
            return
        }
        lastRegion = (global, displayID)

        timer.run(seconds: timerSeconds, displayID: displayID) { [weak self] in
            self?.captureRegionLive(global, on: displayID)
        }
    }

    func capturePreviousArea() {
        rememberBeautifySkip()
        if captureHeldFreezeCroppingLastRegion() {
            return
        }
        guard let lastRegion else {
            // Nothing to repeat is not a failure worth a banner, but it must not be
            // silence either: the system's "can't do that" sound (T-CAP-6).
            logger.info("No previous area to capture yet")
            NSSound.beep()
            automation.report(.failed("There is no previous area to capture yet."))
            return
        }
        guard recovery.allowCapture(permissions: permissions, onPicker: { [weak self] in
            self?.captureWithSystemPicker()
        }) else { return }

        inFlight?.cancel()
        let region = lastRegion
        timer.run(seconds: timerSeconds, displayID: region.displayID) { [weak self] in
            self?.captureRegionLive(region.rect, on: region.displayID)
        }
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        timerAlreadyRan = false
        timer.cancel()
        overlay.cancel()
        onArmedStateChanged?()
    }

    // MARK: - Completion

    /// The countdown this selection still owes: none if the Self-Timer already ran.
    private func remainingTimerSeconds() -> Int {
        defer { timerAlreadyRan = false }
        return timerAlreadyRan ? 0 : timerSeconds
    }

    private func finish(with outcome: SelectionOutcome?, freezes: [DisplayFreeze]) {
        let seconds = remainingTimerSeconds()
        switch outcome {
        case nil:
            logger.info("Capture cancelled")
            automation.report(.cancelled)
        case let .region(result):
            finishRegion(result, freezes: freezes, timerSeconds: seconds)
        case let .window(selection):
            finishWindow(selection, timerSeconds: seconds)
        case let .fullscreen(displayID):
            finishFullscreen(displayID, freezes: freezes, timerSeconds: seconds)
        }
    }

    /// `F` on the overlay: the whole frozen display, still WYSIWYG (docs/03 §1.3).
    private func finishFullscreen(_ displayID: CGDirectDisplayID, freezes: [DisplayFreeze], timerSeconds: Int) {
        guard let freeze = freezes.first(where: { $0.geometry.displayID == displayID }) else {
            captureDisplay(displayID)
            return
        }
        let local = freeze.geometry.localRect(for: freeze.geometry.frame)
        finishRegion(
            SelectionResult(
                rect: freeze.geometry.frame,
                display: freeze.geometry,
                localRect: local.cgRect
            ),
            freezes: freezes,
            timerSeconds: timerSeconds
        )
    }

    /// Captures the picked window through SCK, so it comes out unoccluded rather than
    /// cropped out of the frozen screen (docs/03 §1.2).
    private func finishWindow(_ selection: WindowSelection, timerSeconds: Int) {
        // Capture Text with W: read the window's text rather than deliver an image card
        // that overwrites the clipboard with a picture (T-CAP-8).
        if purpose == .recognizeText {
            recognizeText(inWindow: selection)
            return
        }
        let shadow = selection.togglesShadow ? !settings.windowShadow : settings.windowShadow
        let options = WindowCaptureOptions(
            includesShadow: shadow,
            // Always keep the window's alpha so a solid or wallpaper fill can show
            // through rounded corners (docs/03 §1.2). Opaque is applied afterwards.
            transparentBackground: true,
            includesCursor: includesCursor
        )

        timer.run(seconds: timerSeconds, displayID: selection.display.displayID) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    let captured = try await engine.captureWindow(selection.window.id, options: options)
                    permissions.noteCaptureSuccess()
                    let presented = WindowBackdropApplier.apply(captured, settings: settings)
                    let spec = WindowBackdropApplier.beautifySpec(
                        settings: settings,
                        displayID: captured.metadata.displayID
                    ) ?? autoBeautifySpec()
                    await deliver(presented, editableOriginal: captured, beautify: spec)
                } catch {
                    handle(error)
                }
            }
        }
    }

    private func finishRegion(_ result: SelectionResult, freezes: [DisplayFreeze], timerSeconds: Int) {
        guard let freeze = freezes.first(where: { $0.geometry.displayID == result.display.displayID }) else {
            logger.error("The selected display's freeze went missing")
            return
        }
        let frozen = FrozenDisplay(geometry: freeze.geometry, image: freeze.image)

        // Capture Text reads the same crop instead of exporting it (docs/03 §1.7).
        if purpose == .recognizeText {
            guard let image = frozen.croppedImage(localRect: result.localRect) else { return }
            recognizeText(in: image, on: result.display.displayID)
            return
        }

        lastRegion = (result.rect, result.display.displayID)

        // With a timer running the point is to capture what the screen looks like *after*
        // the countdown, so the frozen image is the wrong source and the region is
        // re-captured live (docs/03 §1.5). Without a timer, cropping the freeze is both
        // faster and the only way to guarantee WYSIWYG (docs/03 §1.1).
        guard timerSeconds == 0 else {
            timer.run(seconds: timerSeconds, displayID: result.display.displayID) { [weak self] in
                self?.captureRegionLive(result.rect, on: result.display.displayID)
            }
            return
        }

        // Cropped from the frozen bitmap, never re-captured — that is what guarantees
        // the file matches what the user selected on (docs/03 §1.1).
        guard let image = frozen.croppedImage(localRect: result.localRect) else {
            logger.error("Could not crop the selection out of the frozen image")
            return
        }

        // Metadata for the crop, not the whole display: the filename template and the
        // history index both read the size from here.
        let capture = Capture(
            image: image,
            metadata: CaptureMetadata(
                source: .region(display: result.display.displayID),
                displayID: result.display.displayID,
                scale: result.display.scale,
                pointRect: result.rect,
                pixelSize: PixelSize(width: image.width, height: image.height),
                colorSpaceName: image.colorSpace?.name as String?,
                frontmostApp: frontmostAtHotkey
            )
        )

        // The signpost lives inside the task so it still measures what it claims to —
        // selection to clipboard, encode included — now that the encode has moved off the
        // main actor (PRD §8, docs/07 H4).
        inFlight = Task { [weak self] in
            guard let self else { return }
            let state = signposter.beginInterval("selectionToClipboard")
            await deliver(capture)
            signposter.endInterval("selectionToClipboard", state)
        }
    }
}
