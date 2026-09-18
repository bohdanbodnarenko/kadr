import SwiftUI

/// In-app Help for technical settings (docs/14 UX-10). Local copy only — no network.
enum KadrHelpTopic: String, CaseIterable, Identifiable {
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
            on, macOS asks for Accessibility so Kadr can read shortcuts — never ordinary typing.
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
            Click the Kadr icon in the menu bar (or press ⇧⌘2) to open the capture island; \
            right-click the icon for History, Settings and Quit. While the island is open, \
            hover a button to see its letter, which starts it (A area, W window, F screen, R record), \
            and the Tools menu shows a letter for each tool. Escape cancels. Return starts the \
            last mode. Out of the box ⌃⇧3 captures the screen, ⌃⇧4 an area, \
            ⌃⇧6 starts a recording and ⌃⇧. stops it; every other command can be given a \
            shortcut in Settings → Shortcuts.
            """
        }
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
    @State private var selection: KadrHelpTopic

    init(topic: KadrHelpTopic = .shortcuts) {
        _selection = State(initialValue: topic)
    }

    var body: some View {
        NavigationSplitView {
            List(KadrHelpTopic.allCases, selection: Binding<KadrHelpTopic?>(
                get: { selection },
                set: {
                    if let topic = $0 {
                        selection = topic
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
