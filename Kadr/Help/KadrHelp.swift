import KeyboardShortcuts
import SwiftUI

/// In-app Help for technical settings (docs/14 UX-10). Local copy only — no network.
///
/// The first five topics are the ones a new user reaches for (docs/17 T-SH-9): how to
/// start, what to do when a shortcut does nothing, what each permission is for, where
/// files go, and how to report a problem.
enum KadrHelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted
    case shortcutNotWorking
    case permissions
    case whereAreMyFiles
    case reportingProblem
    case recordingFormat
    case recordingAudio
    case studioCapture
    case overlays
    case scrolling
    case desktopHygiene
    case saveTarget
    case shortcuts

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .gettingStarted: String(localized: "Getting started")
        case .shortcutNotWorking: String(localized: "Nothing happens when I press the shortcut")
        case .permissions: String(localized: "Permissions")
        case .whereAreMyFiles: String(localized: "Where are my files?")
        case .reportingProblem: String(localized: "Reporting a problem")
        case .recordingFormat: String(localized: "Recording format")
        case .recordingAudio: String(localized: "Recording audio")
        case .studioCapture: String(localized: "Studio capture")
        case .overlays: String(localized: "Click and key overlays")
        case .scrolling: String(localized: "Scrolling capture")
        case .desktopHygiene: String(localized: "Desktop while capturing")
        case .saveTarget: String(localized: "Where captures are saved")
        case .shortcuts: String(localized: "Keyboard shortcuts")
        }
    }

    var body: String {
        switch self {
        case .gettingStarted:
            """
            Kadr lives in the menu bar. Click its icon, or press \(Self.shortcutText(.allInOne)), \
            to open the capture island, then choose an area, a window, the whole screen or a \
            recording. Right-click the icon for History, Settings and Quit. After a capture a \
            card appears in the corner: drag it anywhere, or use its buttons to copy, save, \
            annotate or pin it.
            """
        case .shortcutNotWorking:
            """
            Another app may already own that shortcut — macOS gives it to whichever app asked \
            first. Open Settings → Shortcuts: a shortcut Kadr could not register is marked \
            there, and you can record a different one. If none of Kadr's shortcuts work, make \
            sure Kadr is running (its icon is in the menu bar) and that Screen Recording is \
            allowed in System Settings → Privacy & Security.
            """
        case .permissions:
            """
            Screen Recording is the one Kadr cannot work without. The others are asked for \
            only when you first use what needs them: Accessibility for auto-scroll and key \
            overlays, Input Monitoring for the click and key overlays, the microphone and \
            camera for recordings that use them, and Speech Recognition for a teleprompter \
            that follows your voice. After allowing Screen Recording or Accessibility macOS \
            may ask you to quit and reopen Kadr. From macOS 15, macOS asks again about Screen \
            Recording every month; choosing Allow keeps Kadr working.
            """
        case .whereAreMyFiles:
            """
            Captures you save go to the folder set in Settings → General (Save to). Every \
            capture, saved or not, is also kept in History for as long as Settings → History \
            says. Recordings keep a small studio session beside them in Kadr's own folder, so \
            you can edit them again later.
            """
        case .reportingProblem:
            """
            Choose Help → Report a Problem…. Kadr writes a diagnostics zip — its own log, crash \
            reports and a description of this Mac's setup, with no captures or file names — \
            shows it in Finder, and opens a bug report form in your browser. Kadr sends \
            nothing itself: attach the zip to the form if you are happy to share it. Help → \
            Export Diagnostics… makes the zip without opening the form.
            """
        case .recordingFormat:
            """
            HEVC makes smaller files and is required for HDR. H.264 is the compatibility option \
            for apps that still cannot open HEVC. SDR is safer for interface shots; HDR keeps \
            the display’s full range.
            """
        case .recordingAudio:
            """
            System audio is captured by ScreenCaptureKit. The microphone is a separate track so \
            you can mute it later in the studio without re-recording. Mono mixes each track down \
            if you need a simpler file.
            """
        case .studioCapture:
            """
            Editable recording data is a few kilobytes beside the movie. It is what lets the \
            studio reconstruct a smooth cursor and zoom after you stop. Turning it off burns \
            the pointer in and those effects cannot be added later.
            """
        case .overlays:
            """
            Click highlights and key overlays are composited into the recording, not drawn on \
            your screen. Key overlays can reveal passwords. The first time you record with keys \
            on, macOS asks for Accessibility and Input Monitoring so Kadr can read shortcuts — \
            never ordinary typing. Without both, the recording runs with no key overlay.
            """
        case .scrolling:
            """
            Manual scrolling needs only Screen Recording: you move the page and Kadr stitches \
            frames. Auto-scroll synthesises scroll events and therefore needs Accessibility, \
            asked the first time you use it.
            """
        case .desktopHygiene:
            """
            Hiding icons and swapping the wallpaper applies only while a capture or recording \
            runs. A crash restores the previous wallpaper. Precision crosshair and edge snapping \
            are overlay aids, not changes to the saved file.
            """
        case .saveTarget:
            """
            The default folder is used for Save on a card and for after-capture Save. “Ask where \
            to save” shows a folder picker instead. The All-in-One strip can switch this per \
            session without opening Settings.
            """
        case .shortcuts:
            """
            Click the Kadr icon in the menu bar (or press \(Self.shortcutText(.allInOne))) to \
            open the capture island; right-click the icon for History, Settings and Quit. While \
            the island is open, hover a button to see its letter, which starts it (A area, \
            W window, F screen, R record), and the Tools menu shows a letter for each tool. \
            Escape cancels. Return starts the last mode.

            Your shortcuts:
            \(Self.shortcutList)

            Any command can be given a shortcut in Settings → Shortcuts.
            """
        }
    }

    /// The shortcut as the user has it now, not as it shipped: hard-coded defaults went
    /// stale the moment somebody rebound one (docs/17 T-SH-9).
    static func shortcutText(_ command: CaptureCommand) -> String {
        KeyboardShortcuts.getShortcut(for: command.shortcutName)?.description
            ?? String(localized: "no shortcut")
    }

    /// One line per command that has a shortcut, in the order Settings lists them.
    static var shortcutList: String {
        let lines = CaptureCommand.allCases.compactMap { command -> String? in
            guard let shortcut = KeyboardShortcuts.getShortcut(for: command.shortcutName) else { return nil }
            return "\(shortcut.description)  \(command.title)"
        }
        return lines.isEmpty ? String(localized: "None set.") : lines.joined(separator: "\n")
    }
}

/// Which topic the Help window shows, so a second request can move an open window to a
/// new topic instead of being ignored (docs/17 T-SH-5).
@MainActor
@Observable
final class KadrHelpNavigation {
    var selection: KadrHelpTopic

    init(selection: KadrHelpTopic) {
        self.selection = selection
    }
}

struct KadrHelpTopicView: View {
    let topic: KadrHelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title)
                .font(.headline)
            Text(topic.body)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 400, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

struct KadrHelpView: View {
    @Bindable var navigation: KadrHelpNavigation

    private var selection: KadrHelpTopic {
        navigation.selection
    }

    var body: some View {
        NavigationSplitView {
            List(KadrHelpTopic.allCases, selection: Binding<KadrHelpTopic?>(
                get: { navigation.selection },
                set: {
                    if let topic = $0 {
                        navigation.selection = topic
                    }
                }
            )) { topic in
                Text(topic.title).tag(topic)
            }
            .navigationTitle("Help")
        } detail: {
            ScrollView {
                KadrHelpTopicView(topic: selection)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 560, minHeight: 360)
        .kadrLayoutDirection()
    }
}

/// A compact control that opens the technical explanation for one setting (docs/14 UX-10).
struct SettingsLearnMore: View {
    let topic: KadrHelpTopic
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help("Learn more")
        .accessibilityLabel("Learn more about \(topic.title)")
        .kadrHitTarget()
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            KadrHelpTopicView(topic: topic)
        }
    }
}
