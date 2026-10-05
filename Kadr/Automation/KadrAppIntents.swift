import AppIntents
import AutomationKit
import Foundation

/// Shortcuts actions (docs/03 §8.4).
///
/// Thin wrappers over the same `AppCommand` values the URL scheme and the CLI produce, so
/// a Shortcuts action cannot drift from its command-line twin. They run in the agent
/// process, because that is where the Screen Recording grant lives (docs/04 §1). The
/// agent is always running, so the capture actions do not ask Shortcuts to *open* it:
/// activating Kadr first would change which app is frontmost, and with it what a window
/// or area capture sees (docs/17 T-OUT-13). Only the actions that show Kadr's own
/// windows open the app.
enum KadrIntentError: Error, CustomLocalizedStringResourceConvertible {
    case cancelled
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .cancelled: "Cancelled."
        case let .failed(message): "\(message)"
        }
    }
}

/// Runs a command in the agent and waits for its answer.
@MainActor
private func run(_ command: AppCommand) async throws -> AutomationResponse {
    let response = await withCheckedContinuation { continuation in
        AppDelegate.performAutomation(command) { continuation.resume(returning: $0) }
    }
    switch response.status {
    case .ok: return response
    case .cancelled: throw KadrIntentError.cancelled
    case .noText: throw KadrIntentError.failed("No text found")
    case .failed, .unsupported, .denied: throw KadrIntentError.failed(response.message ?? "Kadr could not do that.")
    }
}

/// The file a capture produced, as something the next Shortcuts action can take.
@MainActor
private func file(from response: AutomationResponse) throws -> IntentFile {
    guard let path = response.paths.first else {
        throw KadrIntentError.failed("Kadr produced no file.")
    }
    return IntentFile(fileURL: URL(fileURLWithPath: path))
}

/// `CaptureAction` as Shortcuts can show it, so a shortcut can say "copy" or "save"
/// rather than inherit whatever Settings says (docs/18 OUT-14).
enum CaptureActionChoice: String, AppEnum {
    case copy
    case save
    case annotate
    case pin
    case overlay

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "After Capture")
    static let caseDisplayRepresentations: [CaptureActionChoice: DisplayRepresentation] = [
        .copy: "Copy to Clipboard",
        .save: "Save",
        .annotate: "Annotate",
        .pin: "Pin to Screen",
        .overlay: "Show Card"
    ]

    var action: CaptureAction {
        CaptureAction(rawValue: rawValue) ?? .overlay
    }
}

/// Capture options carrying a shortcut's chosen action; nil keeps Settings' choice.
private func options(_ choice: CaptureActionChoice?) -> CaptureOptions {
    var options = CaptureOptions.none
    options.action = choice?.action
    return options
}

struct CaptureAreaIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Area"
    static let description = IntentDescription("Select an area of the screen and capture it.")
    static let openAppWhenRun = false

    @Parameter(title: "After Capture", description: "Leave empty to use Kadr's setting.")
    var action: CaptureActionChoice?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.captureArea(options(action)))))
    }
}

struct CaptureWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Window"
    static let description = IntentDescription("Pick a window and capture it.")
    static let openAppWhenRun = false

    @Parameter(title: "After Capture", description: "Leave empty to use Kadr's setting.")
    var action: CaptureActionChoice?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.captureWindow(options(action)))))
    }
}

struct CaptureFullscreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Screen"
    static let description = IntentDescription("Capture the whole screen.")
    static let openAppWhenRun = false

    @Parameter(title: "After Capture", description: "Leave empty to use Kadr's setting.")
    var action: CaptureActionChoice?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.captureFullscreen(options(action)))))
    }
}

struct CapturePreviousAreaIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Previous Area"
    static let description = IntentDescription("Re-capture the last selected area.")
    static let openAppWhenRun = false

    @Parameter(title: "After Capture", description: "Leave empty to use Kadr's setting.")
    var action: CaptureActionChoice?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.capturePreviousArea(options(action)))))
    }
}

struct CaptureScrollingIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Scrolling Area"
    static let description = IntentDescription("Capture a scrolling region and stitch it.")
    static let openAppWhenRun = false

    @Parameter(title: "After Capture", description: "Leave empty to use Kadr's setting.")
    var action: CaptureActionChoice?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.captureScrolling(options(action)))))
    }
}

struct RecordRegionIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Region"
    static let description = IntentDescription("Select a region and start recording it.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(.recordRegion(RecordOptions()))
        return .result()
    }
}

struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Text"
    static let description = IntentDescription("Select an area and read the text in it.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await .result(value: run(.captureText(.none)).text ?? "")
    }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Start recording the screen.")
    static let openAppWhenRun = false

    @Parameter(title: "Frames per Second")
    var frameRate: Int?

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(.recordScreen(RecordOptions(frameRate: frameRate)))
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stop the recording and return the file.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.stopRecording)))
    }
}

struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Recording"
    static let description = IntentDescription("Start or stop a screen recording.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        if AppDelegate.shared.recordingStorage?.isRecording == true {
            _ = try await run(.stopRecording)
        } else {
            _ = try await run(.recordScreen(RecordOptions()))
        }
        return .result()
    }
}

struct PinImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Image"
    static let description = IntentDescription("Show an image on top of every window.")
    static let openAppWhenRun = false

    /// No `supportedContentTypes:` — that initialiser is macOS 15+, and Kadr ships to 14.
    /// A file that is not an image simply fails to pin, with a message that says so.
    @Parameter(title: "Image")
    var image: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(.pin(FileTarget(path: pinnableURL().path)))
        return .result()
    }

    /// The image as a file. Shortcuts often passes images in memory — from the clipboard,
    /// a photo or another app's output — which used to be refused outright (docs/18
    /// OUT-14). Those go where clipboard pins keep their bytes, which survives the relaunch
    /// a restored pin needs and is removed with the pin.
    @MainActor
    private func pinnableURL() throws -> URL {
        if let url = image.fileURL {
            return url
        }
        guard let directory = AppDelegate.shared.areaCaptureStorage?.pins.clipboardDirectory else {
            throw KadrIntentError.failed("Kadr could not read that image.")
        }
        let name = (image.filename as NSString).lastPathComponent
        let base = name.isEmpty ? "Pinned Image" : (name as NSString).deletingPathExtension
        let given = (name as NSString).pathExtension
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory
                .appendingPathComponent("\(base) \(UUID().uuidString)")
                .appendingPathExtension(given.isEmpty ? "png" : given)
            try image.data.write(to: url, options: .atomic)
            return url
        } catch {
            throw KadrIntentError.failed("Kadr could not read that image.")
        }
    }
}

/// `ToggleState` as Shortcuts can show it. The AutomationKit enum stays free of
/// AppIntents, which is a UI framework it has no business linking.
enum DesktopIconsState: String, AppEnum {
    case hide
    case show
    case toggle

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Desktop Icons")
    static let caseDisplayRepresentations: [DesktopIconsState: DisplayRepresentation] = [
        .hide: "Hide",
        .show: "Show",
        .toggle: "Toggle"
    ]

    var command: ToggleState {
        switch self {
        case .hide: .on
        case .show: .off
        case .toggle: .toggle
        }
    }
}

struct ToggleDesktopIconsIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Desktop Icons"
    static let description = IntentDescription("Hide or show the icons on the desktop.")
    static let openAppWhenRun = true

    @Parameter(title: "Action", default: .toggle)
    var state: DesktopIconsState

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(.toggleDesktopIcons(state.command))
        return .result()
    }
}

struct OpenAllInOneIntent: AppIntent {
    static let title: LocalizedStringResource = "All-in-One"
    static let description = IntentDescription("Open Kadr's All-in-One capture HUD.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(.allInOne(.none))
        return .result()
    }
}

struct OpenHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open History"
    static let description = IntentDescription("Open Kadr's capture library.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(.openHistory)
        return .result()
    }
}

/// Siri phrases for the handful of actions worth saying out loud.
struct KadrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureAreaIntent(),
            phrases: ["Capture an area with \(.applicationName)"],
            shortTitle: "Capture Area",
            systemImageName: "viewfinder"
        )
        AppShortcut(
            intent: CaptureTextIntent(),
            phrases: ["Capture text with \(.applicationName)"],
            shortTitle: "Capture Text",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: CaptureWindowIntent(),
            phrases: ["Capture a window with \(.applicationName)"],
            shortTitle: "Capture Window",
            systemImageName: "macwindow"
        )
        AppShortcut(
            intent: CaptureFullscreenIntent(),
            phrases: ["Capture the screen with \(.applicationName)"],
            shortTitle: "Capture Screen",
            systemImageName: "rectangle.dashed"
        )
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording with \(.applicationName)"],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["Toggle recording with \(.applicationName)"],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording with \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
