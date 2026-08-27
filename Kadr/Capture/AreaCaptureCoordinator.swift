import AppKit
import CaptureCore
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
    private let permissions: PermissionCoordinator
    private let overlay: SelectionOverlayController
    private let settings: AppSettings
    private let timer = CaptureCountdown()
    private let vision = VisionClient()
    private let recovery = PermissionRecovery()
    private var pickerSession: ContentSharingPickerSession?
    private let toast = TextCaptureToast()
    private let output: CaptureOutput
    private let quickAccess: QuickAccessManager
    private let pins = PinManager()
    private let logger = KadrLog.logger(.capture)
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

    init(
        engine: CaptureEngine,
        permissions: PermissionCoordinator,
        settings: AppSettings,
        overlay: SelectionOverlayController = SelectionOverlayController()
    ) {
        self.engine = engine
        self.permissions = permissions
        self.settings = settings
        self.overlay = overlay
        let output = CaptureOutput(settings: settings)
        self.output = output
        quickAccess = QuickAccessManager(settings: settings, output: output, pins: pins)
    }

    var hasPreviousRegion: Bool {
        lastRegion != nil
    }

    /// Freezes every display and puts the selection overlay up.
    func beginAreaCapture() {
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
        let seconds = settings.timerSeconds
        timer.run(seconds: seconds) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    let captures = try await engine.captureAllDisplays(
                        includesCursor: settings.includesCursor
                    )
                    permissions.noteCaptureSuccess()
                    for capture in captures {
                        deliver(capture)
                    }
                } catch {
                    handle(error)
                }
            }
        }
    }

    private func beginOverlayCapture(mode: SelectionMode, purpose: SelectionPurpose = .capture) {
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

                overlay.present(
                    freezes: freezes.map { FrozenDisplay(geometry: $0.geometry, image: $0.image) },
                    mode: mode,
                    purpose: purpose,
                    windows: windows,
                    signpostState: interval
                ) { [weak self] outcome in
                    self?.finish(with: outcome, freezes: freezes)
                }
            } catch {
                signposter.endInterval("hotkeyToOverlay", interval)
                handle(error)
            }
        }
    }

    /// Repeats the last region with no UI at all (docs/03 §1.1).
    func capturePreviousArea() {
        guard let lastRegion else {
            logger.info("No previous area to capture yet")
            return
        }

        inFlight?.cancel()
        let region = lastRegion
        timer.run(seconds: settings.timerSeconds) { [weak self] in
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
            includesCursor: settings.includesCursor
        )

        timer.run(seconds: settings.timerSeconds) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    let capture = try await engine.captureWindow(selection.window.id, options: options)
                    permissions.noteCaptureSuccess()
                    deliver(capture)
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
        guard settings.timerSeconds == 0 else {
            timer.run(seconds: settings.timerSeconds) { [weak self] in
                self?.captureRegionLive(result.rect, on: result.display.displayID)
            }
            return
        }

        let state = signposter.beginInterval("selectionToClipboard")
        defer { signposter.endInterval("selectionToClipboard", state) }

        // Cropped from the frozen bitmap, never re-captured — that is what guarantees
        // the file matches what the user selected on (docs/03 §1.1).
        guard let image = frozen.croppedImage(localRect: result.localRect) else {
            logger.error("Could not crop the selection out of the frozen image")
            return
        }

        // Metadata for the crop, not the whole display: the filename template and the
        // history index both read the size from here.
        deliver(Capture(
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
        ))
    }

    /// Sends a crop to the Vision helper and puts the result on the clipboard.
    private func recognizeText(in image: CGImage, on displayID: CGDirectDisplayID) {
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let options = TextRecognitionOptions(
                    preservesLineBreaks: settings.ocrPreservesLineBreaks
                )
                let analysis = try await vision.analyze(image, options: options)
                let text = analysis.text(preservingLineBreaks: settings.ocrPreservesLineBreaks)

                if !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                let characters = text.count
                logger.info("Recognised \(characters, privacy: .public) characters")

                let screen = NSScreen.screens.first { ScreenDescriptor($0)?.displayID == displayID }
                toast.show(text: text, codes: analysis.codes, on: screen)

                // Let go of the connection so the helper can start its idle countdown
                // and give its Vision models back (docs/04 §1).
                vision.disconnect()
            } catch {
                logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                vision.disconnect()
            }
        }
    }

    private func captureRegionLive(_ rect: DisplayRect, on displayID: CGDirectDisplayID) {
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await engine.captureRegion(
                    rect,
                    on: displayID,
                    includesCursor: settings.includesCursor
                )
                permissions.noteCaptureSuccess()
                deliver(capture)
            } catch {
                handle(error)
            }
        }
    }

    /// Exports a capture and puts a card up for it (docs/03 §2).
    private func deliver(_ capture: Capture) {
        guard let result = output.deliver(capture) else { return }
        quickAccess.show(result, capture: capture)
    }

    /// Brings back the most recently dismissed card (docs/03 §2).
    func restoreRecentlyClosed() {
        quickAccess.restoreRecentlyClosed()
    }

    /// The "Close all pins" global command (docs/03 §4).
    func closeAllPins() {
        pins.closeAll()
    }

    var pinCount: Int {
        pins.count
    }

    /// The frontmost app right now, as a value.
    private static func currentFrontmostApp() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppIdentity(name: app.localizedName, bundleIdentifier: app.bundleIdentifier)
    }

    private func handle(_ error: any Error) {
        if error is CancellationError {
            return
        }
        permissions.noteCaptureFailure(error)
        let mapped = CaptureError.mapping(error)
        logger.error("Capture failed: \(mapped.errorDescription ?? "unknown", privacy: .public)")

        // A lost grant is the one failure worth interrupting the user over: every capture
        // will keep failing until they act (docs/03 §9).
        guard mapped.indicatesPermissionLoss else { return }
        switch recovery.present(state: permissions.state) {
        case .openSettings:
            recovery.openSystemSettings()
        case .usePicker:
            captureWithSystemPicker()
        case .dismiss:
            break
        }
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
                deliver(capture)
            } catch is CancellationError {
                logger.info("Picker capture cancelled")
            } catch {
                let mapped = CaptureError.mapping(error)
                logger.error("Picker capture failed: \(mapped.errorDescription ?? "unknown", privacy: .public)")
            }
        }
    }
}
