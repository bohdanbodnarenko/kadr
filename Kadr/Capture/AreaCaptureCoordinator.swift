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
    private let engine: CaptureEngine
    /// Internal, not private: the failure path lives in
    /// `AreaCaptureCoordinator+Delivery.swift`, and `private` is file-scoped.
    let permissions: PermissionCoordinator
    private let overlay: SelectionOverlayController
    /// Internal, not private: delivery reads the after-capture matrix, and `private` is
    /// file-scoped.
    let settings: AppSettings
    private let timer = CaptureCountdown()
    private let vision = TextRecognizer()
    let recovery = PermissionRecovery()
    private var pickerSession: ContentSharingPickerSession?
    /// Internal, not private: the colour-pick half lives in
    /// `AreaCaptureCoordinator+ColorPick.swift`, and `private` is file-scoped.
    let toast = TextCaptureToast()
    /// Internal, not private: delivery lives in
    /// `AreaCaptureCoordinator+Delivery.swift`, and `private` is file-scoped.
    let output: CaptureOutput
    /// Internal, not private: the overlay-facing forwarders live in
    /// `AreaCaptureCoordinator+Overlay.swift`, and `private` is file-scoped.
    let quickAccess: QuickAccessManager
    let pins = PinManager()
    private let hygiene: DesktopHygieneController?
    let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    private var inFlight: Task<Void, Never>?

    /// The last committed region, for "capture previous area" (docs/03 §1.1).
    private var lastRegion: (rect: DisplayRect, displayID: CGDirectDisplayID)?

    /// The app that was in front when the hotkey fired.
    ///
    /// Sampled then, not at capture time: by the time the overlay is up the frontmost app
    /// is Kadr, which makes a useless `{app}` in the filename.
    private var frontmostAtHotkey: AppIdentity?
    private var purpose: SelectionPurpose = .capture
    /// Whether the next overlay opens as a colour picker (docs/03 §3 P3, docs/06 M22).
    var startsInEyedropperMode = false

    /// The automation request this capture is serving, if any (docs/03 §8.4).
    ///
    /// Cleared the moment the capture reports, so an automated capture cannot leak its
    /// `action=` into the next one the user takes by hand.
    let automation = AutomationCaptureRequest()

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
    }

    var hasPreviousRegion: Bool {
        lastRegion != nil
    }

    /// How long this capture waits: the automation's `delay=` if it gave one, otherwise
    /// the user's self-timer (docs/03 §1.5, §8.4).
    private var timerSeconds: Int {
        automation.overrides.delaySeconds ?? settings.timerSeconds
    }

    /// Whether to draw the pointer, honouring an automation override (docs/03 §8.4).
    private var includesCursor: Bool {
        automation.overrides.includesCursor ?? settings.includesCursor
    }

    /// Arms the next capture with automation's overrides and a place to report to
    /// (docs/03 §8.4).
    func arm(_ overrides: CaptureOverrides, completion: ((CaptureOutcome) -> Void)?) {
        automation.arm(overrides, completion: completion)
    }

    /// Freezes every display and puts the selection overlay up.
    func beginAreaCapture() {
        beginOverlayCapture(mode: .area)
    }

    /// The P1 freeze as its own command: freeze to inspect, then capture as usual (docs/03 §7).
    func toggleFreezeScreen() {
        if overlay.isPresented {
            cancel()
            return
        }
        beginOverlayCapture(mode: .area)
    }

    /// Freezes every display and opens window-pick mode (docs/03 §1.2).
    func beginWindowCapture() {
        beginOverlayCapture(mode: .window)
    }

    /// The same selection interaction, tinted, whose result goes to the recogniser
    /// instead of to a file (docs/03 §1.7).
    func beginTextCapture() {
        beginOverlayCapture(mode: .area, purpose: .recognizeText)
    }

    /// Captures every display with no overlay at all (docs/03 §1.3).
    func captureAllDisplays() {
        inFlight?.cancel()
        let seconds = timerSeconds
        timer.run(seconds: seconds) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    await engine.setDynamicRange(settings.captureDynamicRange)
                    // Before the pixels, not after: hiding the icons or swapping the
                    // wallpaper afterwards leaves them in the shot and restarts the Finder
                    // for nothing (docs/07 H3).
                    await hygiene?.beginCaptureAndSettle()
                    await CaptureExclusionPush.into(engine)
                    let captures = try await engine.captureAllDisplays(
                        includesCursor: includesCursor
                    )
                    permissions.noteCaptureSuccess()
                    await deliverAll(captures)
                    hygiene?.endCapture()
                } catch {
                    hygiene?.endCapture()
                    handle(error)
                }
            }
        }
    }

    func beginOverlayCapture(mode: SelectionMode, purpose: SelectionPurpose = .capture) {
        frontmostAtHotkey = Self.currentFrontmostApp()
        self.purpose = purpose
        // A second hotkey re-freezes rather than stacking overlays (docs/03 §1.1).
        inFlight?.cancel()

        // Opened here so the interval covers the freeze, which is the expensive half of
        // the < 100 ms hotkey-to-overlay budget (PRD §8).
        let interval = signposter.beginInterval("hotkeyToOverlay")

        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                // Applied before the freeze, because an area capture is cropped out of it
                // and has to be in the same range as the file (docs/06 M25).
                await engine.setDynamicRange(settings.captureDynamicRange)
                await CaptureExclusionPush.into(engine)
                let freezes = try await engine.freezeAllDisplays()
                guard !Task.isCancelled else { return }
                permissions.noteCaptureSuccess()

                let windows: [PickableWindowDescriptor] = if mode == .window {
                    try await engine.shareableContent().windows
                        .filter(\.isUserWindow)
                        .map {
                            PickableWindowDescriptor(
                                id: $0.id,
                                title: $0.title,
                                applicationName: $0.applicationName,
                                bundleIdentifier: $0.bundleIdentifier,
                                globalFrame: $0.frame
                            )
                        }
                } else {
                    []
                }

                // Set before presenting, so the detection pass the overlay kicks off is
                // skipped entirely when the user has snapping off (docs/06 M21).
                overlay.snapsToEdges = settings.captureSnapsToEdges
                overlay.onColorPicked = { [weak self] pick in
                    self?.deliver(pick)
                }
                let eyedropper = startsInEyedropperMode
                startsInEyedropperMode = false
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
                }
                overlay.onPrecisionModeChanged = { [weak self] enabled in
                    self?.settings.capturePrecisionCrosshair = enabled
                }
                hygiene?.beginCapture()
            } catch {
                signposter.endInterval("hotkeyToOverlay", interval)
                handle(error)
            }
        }
    }

    /// Repeats the last region with no UI at all (docs/03 §1.1).
    /// Captures a rectangle automation named, with no overlay at all (docs/03 §8.4).
    ///
    /// The rect arrives in AppKit's screen space because that is what a user reads off a
    /// window's frame; it is flipped into CoreGraphics' display space and matched to the
    /// display it lands on here, so nothing downstream has to guess (CLAUDE.md rule 6).
    func captureRegion(_ screenRect: ScreenRect) {
        inFlight?.cancel()
        frontmostAtHotkey = Self.currentFrontmostApp()
        purpose = .capture

        let global = screenRect.inDisplaySpace(.current)
        guard let displayID = DisplayLookup.display(containing: global) else {
            logger.error("The requested region is not on any display")
            automation.report(.failed("That region is not on any display."))
            return
        }
        lastRegion = (global, displayID)

        timer.run(seconds: timerSeconds) { [weak self] in
            self?.captureRegionLive(global, on: displayID)
        }
    }

    func capturePreviousArea() {
        guard let lastRegion else {
            logger.info("No previous area to capture yet")
            return
        }

        inFlight?.cancel()
        let region = lastRegion
        timer.run(seconds: timerSeconds) { [weak self] in
            self?.captureRegionLive(region.rect, on: region.displayID)
        }
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        timer.cancel()
        overlay.cancel()
    }

    // MARK: - Completion

    private func finish(with outcome: SelectionOutcome?, freezes: [DisplayFreeze]) {
        switch outcome {
        case nil:
            logger.info("Capture cancelled")
            automation.report(.cancelled)
        case let .region(result):
            finishRegion(result, freezes: freezes)
        case let .window(selection):
            finishWindow(selection)
        }
    }

    /// Captures the picked window through SCK, so it comes out unoccluded rather than
    /// cropped out of the frozen screen (docs/03 §1.2).
    private func finishWindow(_ selection: WindowSelection) {
        let shadow = selection.togglesShadow ? !settings.windowShadow : settings.windowShadow
        let options = WindowCaptureOptions(
            includesShadow: shadow,
            transparentBackground: settings.transparentWindowBackground,
            includesCursor: includesCursor
        )

        timer.run(seconds: timerSeconds) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    let capture = try await engine.captureWindow(selection.window.id, options: options)
                    permissions.noteCaptureSuccess()
                    await deliver(capture)
                } catch {
                    handle(error)
                }
            }
        }
    }

    private func finishRegion(_ result: SelectionResult, freezes: [DisplayFreeze]) {
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
            timer.run(seconds: timerSeconds) { [weak self] in
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

    /// Sends a crop to the Vision helper and puts the result on the clipboard.
    private func recognizeText(in image: CGImage, on displayID: CGDirectDisplayID) {
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let recognition = try await vision.recognize(
                    image,
                    preservingLineBreaks: settings.ocrPreservesLineBreaks
                )
                vision.copyToClipboard(recognition)
                let characters = recognition.text.count
                logger.info("Recognised \(characters, privacy: .public) characters")

                let screen = NSScreen.screens.first { ScreenDescriptor($0)?.displayID == displayID }
                toast.show(
                    text: recognition.text,
                    codes: recognition.codes,
                    table: recognition.table,
                    on: screen
                )
                automation.report(.text(recognition.text))
            } catch {
                logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                automation.report(.failed(error.localizedDescription))
            }
        }
    }

    private func captureRegionLive(_ rect: DisplayRect, on displayID: CGDirectDisplayID) {
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                // Before the pixels, not after (docs/07 H3).
                await hygiene?.beginCaptureAndSettle()
                await CaptureExclusionPush.into(engine)
                let capture = try await engine.captureRegion(
                    rect,
                    on: displayID,
                    includesCursor: includesCursor
                )
                permissions.noteCaptureSuccess()
                await deliver(capture)
                hygiene?.endCapture()
            } catch {
                hygiene?.endCapture()
                handle(error)
            }
        }
    }

    /// The frontmost app right now, as a value.
    private static func currentFrontmostApp() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppIdentity(name: app.localizedName, bundleIdentifier: app.bundleIdentifier)
    }

    /// Captures through `SCContentSharingPicker`, which needs no permission at all
    /// (docs/04 §4.1) — the way to stay useful before, or without, a TCC grant.
    func captureWithSystemPicker() {
        let session = ContentSharingPickerSession()
        pickerSession = session
        inFlight = Task { [weak self] in
            guard let self else { return }
            defer { pickerSession = nil }
            do {
                let capture = try await session.captureUserSelection()
                await deliver(capture)
            } catch is CancellationError {
                logger.info("Picker capture cancelled")
            } catch {
                let mapped = CaptureError.mapping(error)
                logger.error("Picker capture failed: \(mapped.errorDescription ?? "unknown", privacy: .public)")
            }
        }
    }
}
