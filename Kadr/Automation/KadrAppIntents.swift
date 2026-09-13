import AppIntents
import AutomationKit
import Foundation

/// Shortcuts actions (docs/03 §8.4).
///
/// Thin wrappers over the same `AppCommand` values the URL scheme and the CLI produce, so
/// a Shortcuts action cannot drift from its command-line twin. They run in the agent
/// process — `openAppWhenRun` — because that is where the Screen Recording grant lives
/// (docs/04 §1).
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
    case .failed, .unsupported: throw KadrIntentError.failed(response.message ?? "Kadr could not do that.")
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

struct CaptureAreaIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Area"
    static let description = IntentDescription("Select an area of the screen and capture it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.captureArea(.none))))
    }
}

struct CaptureWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Window"
    static let description = IntentDescription("Pick a window and capture it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.captureWindow(.none))))
    }
}

struct CaptureFullscreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Screen"
    static let description = IntentDescription("Capture the whole screen.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.captureFullscreen(.none))))
    }
}

struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Text"
    static let description = IntentDescription("Select an area and read the text in it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await .result(value: run(.captureText(.none)).text ?? "")
    }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Start recording the screen.")
    static let openAppWhenRun = true

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
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try await .result(value: file(from: run(.stopRecording)))
    }
}

struct PinImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Image"
    static let description = IntentDescription("Show an image on top of every window.")
    static let openAppWhenRun = true

    /// No `supportedContentTypes:` — that initialiser is macOS 15+, and Kadr ships to 14.
    /// A file that is not an image simply fails to pin, with a message that says so.
    @Parameter(title: "Image")
    var image: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = image.fileURL else {
            throw KadrIntentError.failed("That image is not a file on disk.")
        }
        _ = try await run(.pin(FileTarget(path: url.path)))
        return .result()
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
            intent: StopRecordingIntent(),
            phrases: ["Stop recording with \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
