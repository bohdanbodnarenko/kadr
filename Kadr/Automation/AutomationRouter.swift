import AppKit
import AutomationKit
import os
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
    private let areaCapture: AreaCaptureCoordinator
    private let scrollCapture: ScrollCaptureCoordinator
    private let recording: RecordingCoordinator
    private let hygiene: DesktopHygieneController
    private let openSettings: (SettingsTab?) -> Void
    private let openHistory: () -> Void
    /// Adds a file to the capture library. Returns false when it is not something the
    /// library can hold.
    private let addToHistory: (URL) -> Bool
    private let logger = KadrLog.logger(.app)

    init(
        areaCapture: AreaCaptureCoordinator,
        scrollCapture: ScrollCaptureCoordinator,
        recording: RecordingCoordinator,
        hygiene: DesktopHygieneController,
        openSettings: @escaping (SettingsTab?) -> Void,
        openHistory: @escaping () -> Void,
        addToHistory: @escaping (URL) -> Bool
    ) {
        self.areaCapture = areaCapture
        self.scrollCapture = scrollCapture
        self.recording = recording
        self.hygiene = hygiene
        self.openSettings = openSettings
        self.openHistory = openHistory
        self.addToHistory = addToHistory
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
            begin(options.region) { self.areaCapture.beginAreaCapture() }

        case let .captureWindow(options):
            areaCapture.arm(CaptureOverrides(options), completion: report)
            areaCapture.beginWindowCapture()

        case let .captureFullscreen(options):
            areaCapture.arm(CaptureOverrides(options), completion: report)
            areaCapture.captureAllDisplays()

        case let .capturePreviousArea(options):
            guard areaCapture.hasPreviousRegion || options.region != nil else {
                completion(.failed("There is no previous area to capture yet."))
                return true
            }
            areaCapture.arm(CaptureOverrides(options), completion: report)
            begin(options.region) { self.areaCapture.capturePreviousArea() }

        case let .captureText(options):
            areaCapture.arm(CaptureOverrides(options), completion: report)
            areaCapture.beginTextCapture()

        case .pickColor:
            areaCapture.arm(.none, completion: report)
            areaCapture.beginColorPick()

        case let .captureScrolling(options):
            // The overrides belong to the capture; the result comes from the stitcher.
            areaCapture.arm(CaptureOverrides(options), completion: nil)
            scrollCapture.arm(completion: report)
            scrollCapture.begin()

        default:
            return false
        }
        return true
    }

    /// Captures the named region directly, or falls back to the interactive flow.
    private func begin(_ region: ScreenRect?, interactively: () -> Void) {
        if let region {
            areaCapture.captureRegion(region)
        } else {
            interactively()
        }
    }

    private func performRecording(
        _ command: AppCommand,
        report: @escaping (CaptureOutcome) -> Void,
        completion: @escaping (AutomationResponse) -> Void
    ) -> Bool {
        switch command {
        case let .recordScreen(options):
            start(RecordingOverrides(options), completion: completion) {
                self.recording.beginDisplayRecording()
            }

        case let .recordRegion(options):
            start(RecordingOverrides(options), completion: completion) {
                self.recording.beginRegionRecording()
            }

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

    /// The verbs that name a file, and the ones that act on cards already on screen.
    private func performFile(
        _ command: AppCommand,
        completion: @escaping (AutomationResponse) -> Void
    ) -> Bool {
        switch command {
        case let .pin(target):
            guard exists(target, completion: completion) else { return true }
            let pinned = areaCapture.pinFile(at: target.url)
            completion(pinned ? .file(target.url.path) : .failed("Kadr could not read \(target.path)."))

        case let .annotate(target):
            guard exists(target, completion: completion) else { return true }
            areaCapture.annotateFile(at: target.url)
            completion(.file(target.url.path))

        case let .addToHistory(target):
            guard exists(target, completion: completion) else { return true }
            let added = addToHistory(target.url)
            completion(added ? .file(target.url.path) : .failed("Kadr could not add \(target.path)."))

        case .closeAllPins:
            areaCapture.closeAllPins()
            completion(.ok)

        case .restoreRecentlyClosed:
            areaCapture.restoreRecentlyClosed()
            completion(.ok)

        default:
            return false
        }
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
