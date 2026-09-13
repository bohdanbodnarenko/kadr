import AppKit
import AutomationKit
import os
import SelectionUI
import Shared

/// Turns an `AppCommand` into something the agent actually does (docs/03 §8.4).
///
/// One router behind all three frontends — the URL scheme, the `kadr` CLI and the
/// Shortcuts actions — so a verb behaves identically however it arrived, and adding a verb
/// means changing one switch rather than three.
///
/// Every command answers through `completion`. Commands that open a window answer at once;
/// commands that capture answer when the capture lands, which may be a minute later if the
/// user is still framing a selection.
@MainActor
final class AutomationRouter {
    let areaCapture: AreaCaptureCoordinator
    let scrollCapture: ScrollCaptureCoordinator
    let recording: RecordingCoordinator
    private let hygiene: DesktopHygieneController
    private let openSettings: (SettingsTab?) -> Void
    private let openHistory: () -> Void
    /// Adds a file to the capture library. Returns false when it is not something the
    /// library can hold.
    private let addToHistory: (URL) -> Bool
    private let openAllInOne: () -> Void
    private let logger = KadrLog.logger(.app)

    init(
        areaCapture: AreaCaptureCoordinator,
        scrollCapture: ScrollCaptureCoordinator,
        recording: RecordingCoordinator,
        hygiene: DesktopHygieneController,
        openSettings: @escaping (SettingsTab?) -> Void,
        openHistory: @escaping () -> Void,
        addToHistory: @escaping (URL) -> Bool,
        openAllInOne: @escaping () -> Void = {}
    ) {
        self.areaCapture = areaCapture
        self.scrollCapture = scrollCapture
        self.recording = recording
        self.hygiene = hygiene
        self.openSettings = openSettings
        self.openHistory = openHistory
        self.addToHistory = addToHistory
        self.openAllInOne = openAllInOne
    }

    /// Runs a command and reports what it produced.
    ///
    /// Split by family rather than written as one switch, for the same reason
    /// `AutomationParser` is: nineteen verbs in one function is a shape that gets worse
    /// with every verb added.
    func perform(_ command: AppCommand, completion: @escaping (AutomationResponse) -> Void) {
        logger.info("Automation: \(command.verb.rawValue, privacy: .public)")
        let report: (CaptureOutcome) -> Void = { completion($0.response) }

        if performCapture(command, report: report, completion: completion) {
            return
        }
        if performRecording(command, report: report, completion: completion) {
            return
        }
        if performFile(command, completion: completion) {
            return
        }
        performChrome(command, completion: completion)
    }

    /// The verbs that take a screenshot. Returns whether the command was one of them.
    private func performCapture(
        _ command: AppCommand,
        report: @escaping (CaptureOutcome) -> Void,
        completion: @escaping (AutomationResponse) -> Void
    ) -> Bool {
        switch command {
        case let .captureArea(options):
            areaCapture.arm(CaptureOverrides(options), completion: report)
            begin(options, report: report) { self.areaCapture.beginAreaCapture() }

        case let .captureWindow(options):
            areaCapture.arm(CaptureOverrides(options), completion: report)
            areaCapture.beginWindowCapture()

        case let .captureFullscreen(options):
            areaCapture.arm(CaptureOverrides(options), completion: report)
            beginFullscreen(options, report: report)

        case let .capturePreviousArea(options):
            guard areaCapture.hasPreviousRegion || options.region != nil else {
                completion(.failed("There is no previous area to capture yet."))
                return true
            }
            areaCapture.arm(CaptureOverrides(options), completion: report)
            begin(options, report: report) { self.areaCapture.capturePreviousArea() }

        case let .captureText(options):
            areaCapture.arm(CaptureOverrides(options), completion: report)
            beginText(options, report: report)

        case .pickColor:
            areaCapture.arm(.none, completion: report)
            areaCapture.beginColorPick()

        case let .captureScrolling(options):
            // The overrides belong to the capture; the result comes from the stitcher.
            areaCapture.arm(CaptureOverrides(options), completion: nil)
            beginScrolling(options, report: report)

        default:
            return performUnifiedCapture(command, report: report, completion: completion)
        }
        return true
    }

    /// All-in-One and self-timer, split out so the main capture switch stays readable.
    private func performUnifiedCapture(
        _ command: AppCommand,
        report: @escaping (CaptureOutcome) -> Void,
        completion: @escaping (AutomationResponse) -> Void
    ) -> Bool {
        switch command {
        case let .allInOne(options):
            beginAllInOne(options, report: report, completion: completion)
        case let .selfTimer(options):
            areaCapture.arm(CaptureOverrides(options), completion: report)
            begin(options, report: report) { self.areaCapture.beginSelfTimedAreaCapture() }
        default:
            return false
        }
        return true
    }

    /// Captures the named region directly, or falls back to the interactive flow.
    private func begin(
        _ options: CaptureOptions,
        report: @escaping (CaptureOutcome) -> Void,
        interactively: () -> Void
    ) {
        switch DisplayLookup.resolve(region: options.region, display: options.display) {
        case let .failed(message):
            report(.failed(message))
        case .interactive, .display:
            interactively()
        case let .region(rect):
            areaCapture.captureRegion(rect)
        }
    }

    private func beginFullscreen(
        _ options: CaptureOptions,
        report: @escaping (CaptureOutcome) -> Void
    ) {
        switch DisplayLookup.resolve(region: options.region, display: options.display) {
        case let .failed(message):
            report(.failed(message))
        case .interactive:
            areaCapture.captureAllDisplays()
        case let .region(rect):
            areaCapture.captureRegion(rect)
        case let .display(id):
            areaCapture.captureDisplay(id)
        }
    }

    private func beginScrolling(
        _ options: CaptureOptions,
        report: @escaping (CaptureOutcome) -> Void
    ) {
        scrollCapture.arm(overrides: ScrollingOverrides(options), completion: report)
        switch DisplayLookup.resolve(region: options.region, display: options.display) {
        case let .failed(message):
            report(.failed(message))
        case .interactive, .display:
            scrollCapture.begin()
        case let .region(rect):
            if options.startsImmediately == false {
                scrollCapture.begin()
            } else {
                scrollCapture.begin(region: rect)
            }
        }
    }

    private func beginAllInOne(
        _ options: CaptureOptions,
        report: @escaping (CaptureOutcome) -> Void,
        completion: @escaping (AutomationResponse) -> Void
    ) {
        switch DisplayLookup.resolve(region: options.region, display: options.display) {
        case let .failed(message):
            completion(.failed(message))
        case .interactive, .display:
            openAllInOne()
            completion(.ok)
        case let .region(rect):
            areaCapture.arm(CaptureOverrides(options), completion: report)
            areaCapture.captureRegion(rect)
        }
    }

    private func performRecording(
        _ command: AppCommand,
        report: @escaping (CaptureOutcome) -> Void,
        completion: @escaping (AutomationResponse) -> Void
    ) -> Bool {
        switch command {
        case let .recordScreen(options):
            beginAutomatedRecording(options, wholeDisplay: true, completion: completion)

        case let .recordRegion(options):
            beginAutomatedRecording(options, wholeDisplay: false, completion: completion)

        case .stopRecording:
            guard recording.isRecording else {
                completion(.failed("Nothing is recording."))
                return true
            }
            recording.stop(reportingTo: report)

        default:
            return false
        }
        return true
    }

    /// Starts a recording, unless one is already running.
    ///
    /// Answers as soon as it is rolling: the file does not exist until the user stops,
    /// and `stop-recording` is what hands the path back (docs/03 §8.4).
    private func start(
        _ overrides: RecordingOverrides,
        completion: (AutomationResponse) -> Void,
        begin: () -> Void
    ) {
        guard !recording.isRecording else {
            completion(.failed("A recording is already running."))
            return
        }
        recording.arm(overrides)
        begin()
        completion(.ok)
    }

    private func beginAutomatedRecording(
        _ options: RecordOptions,
        wholeDisplay: Bool,
        completion: @escaping (AutomationResponse) -> Void
    ) {
        switch DisplayLookup.resolve(region: options.region, display: options.display) {
        case let .failed(message):
            completion(.failed(message))
        case let target:
            start(RecordingOverrides(options), completion: completion) {
                self.applyRecording(target, wholeDisplay: wholeDisplay)
            }
        }
    }

    private func applyRecording(_ target: AutomationTarget, wholeDisplay: Bool) {
        switch target {
        case .interactive:
            if wholeDisplay {
                recording.beginDisplayRecording()
            } else {
                recording.beginRegionRecording()
            }
        case let .region(rect):
            recording.beginRegionRecording(rect)
        case let .display(id):
            if wholeDisplay {
                recording.beginDisplayRecording(id)
            } else {
                recording.beginRegionRecording()
            }
        case .failed:
            break
        }
    }

    /// The verbs that name a file, and the ones that act on cards already on screen.
    private func performFile(
        _ command: AppCommand,
        completion: @escaping (AutomationResponse) -> Void
    ) -> Bool {
        if performNamedFile(command, completion: completion) {
            return true
        }
        switch command {
        case .openFromClipboard:
            let opened = areaCapture.presentFromClipboard()
            completion(opened ? .ok : .failed("The clipboard does not hold an image or a file."))
        case .closeAllPins:
            areaCapture.closeAllPins()
            completion(.ok)
        case .hidePins:
            areaCapture.togglePinsHidden()
            completion(.ok)
        case .restoreRecentlyClosed:
            areaCapture.restoreRecentlyClosed()
            completion(.ok)
        default:
            return performOverlayStack(command, completion: completion)
        }
        return true
    }

    /// Verbs that take a path (or offer an open panel when pin has none).
    private func performNamedFile(
        _ command: AppCommand,
        completion: @escaping (AutomationResponse) -> Void
    ) -> Bool {
        switch command {
        case let .pin(target):
            performPin(target, completion: completion)
        case let .annotate(target):
            guard exists(target, completion: completion) else { return true }
            areaCapture.annotateFile(at: target.url)
            completion(.file(target.url.path))
        case let .addToHistory(target):
            guard exists(target, completion: completion) else { return true }
            let added = addToHistory(target.url)
            completion(added ? .file(target.url.path) : .failed("Kadr could not add \(target.path)."))
        case let .addQuickAccessOverlay(target):
            guard exists(target, completion: completion) else { return true }
            let shown = areaCapture.presentExternalFile(at: target.url)
            completion(shown ? .file(target.url.path) : .failed("Kadr could not read \(target.path)."))
        default:
            return false
        }
        return true
    }

    private func performPin(_ target: FileTarget?, completion: @escaping (AutomationResponse) -> Void) {
        if let target {
            guard exists(target, completion: completion) else { return }
            let pinned = areaCapture.pinFile(at: target.url)
            completion(pinned ? .file(target.url.path) : .failed("Kadr could not read \(target.path)."))
        } else if let url = areaCapture.pinFromOpenPanel() {
            completion(.file(url.path))
        } else {
            completion(.cancelled)
        }
    }

    /// Overlay-stack verbs (CleanShot §6.3), kept off the file-path switch.
    private func performOverlayStack(
        _ command: AppCommand,
        completion: @escaping (AutomationResponse) -> Void
    ) -> Bool {
        switch command {
        case .closeAllOverlays:
            areaCapture.closeAllOverlays()
        case .saveAllOverlays:
            areaCapture.saveAllOverlays()
        case .hideOverlays:
            areaCapture.toggleOverlaysHidden()
        default:
            return false
        }
        completion(.ok)
        return true
    }

    /// Reports a missing file rather than letting a pin quietly open nothing.
    private func exists(_ target: FileTarget, completion: (AutomationResponse) -> Void) -> Bool {
        guard FileManager.default.fileExists(atPath: target.url.path) else {
            completion(.failed("No file at \(target.path)."))
            return false
        }
        return true
    }

    /// Everything that opens a window or flips a switch.
    private func performChrome(_ command: AppCommand, completion: @escaping (AutomationResponse) -> Void) {
        switch command {
        case let .toggleDesktopIcons(state):
            hygiene.setUserHide(hidden(from: state))
        case .freezeScreen:
            // No completion: freezing is a toggle, not a capture, and the capture that
            // may follow it belongs to whoever asks for one next.
            areaCapture.arm(.none, completion: nil)
            areaCapture.toggleFreezeScreen()
        case .openHistory:
            openHistory()
        case let .openSettings(tab):
            openSettings(tab)
        case .version:
            completion(AutomationResponse(status: .ok, text: Self.versionString))
            return
        default:
            completion(.failed("Kadr does not know how to do that."))
            return
        }
        completion(.ok)
    }

    /// What `state=` means for the icons, given where they are now.
    private func hidden(from state: ToggleState) -> Bool {
        switch state {
        case .on: true
        case .off: false
        case .toggle: !hygiene.isHidingIcons
        }
    }

    /// `CFBundleShortVersionString (build)`, the same string Settings shows.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
