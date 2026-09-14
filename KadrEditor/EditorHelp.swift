import AppKit
import EditorUI
import SwiftUI

/// Editor/studio Help. Bundled copy — Help does not open the network (docs/14 UX-10, UX-28).
enum EditorHelpTopic: String, CaseIterable, Identifiable {
    case editor
    case studio
    case shortcuts

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .editor: String(localized: "Annotation editor")
        case .studio: String(localized: "Recording studio")
        case .shortcuts: String(localized: "Keyboard shortcuts")
        }
    }

    var body: String {
        switch self {
        case .editor:
            """
            Select, draw, and crop live on the capture. Copy and Share export the image you see, \
            including annotations. Save Project writes a re-editable .kadr beside the file. \
            Reduce Motion replaces chrome motion with a cross-fade.
            """
        case .studio:
            """
            Copy and Share export the current edit, not the original file. Copy Original and \
            Share Original are in the overflow menu. Trim and zoom handles have 20-point hit \
            targets; arrow keys nudge the playhead, Shift-arrows trim, Option-arrows take larger \
            steps.
            """
        case .shortcuts:
            """
            ⌘Z / ⇧⌘Z undo and redo. ⌘C copies the current edit. ⌘S saves. ⌘I shows or hides the \
            inspector. ⌘= / ⌘- zoom the canvas. In the studio, arrows move the playhead, Return \
            opens a selected cue, Delete removes it with Undo.
            """
        }
    }
}

struct EditorHelpView: View {
    @State private var selection: EditorHelpTopic

    init(topic: EditorHelpTopic = .shortcuts) {
        _selection = State(initialValue: topic)
    }

    var body: some View {
        NavigationSplitView {
            List(EditorHelpTopic.allCases, selection: Binding<EditorHelpTopic?>(
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(selection.title)
                        .font(.headline)
                    Text(selection.body)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 560, minHeight: 360)
        .editorLayoutDirection()
    }
}

@MainActor
final class EditorHelpWindowController: NSObject, NSWindowDelegate {
    static let shared = EditorHelpWindowController()
    private var window: NSWindow?

    func show(topic: EditorHelpTopic = .shortcuts) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: EditorHelpView(topic: topic))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kadr Help"
        window.contentViewController = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window?.contentViewController = nil
        window = nil
    }
}
