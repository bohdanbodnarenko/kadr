import AppKit
import EditorUI
import SwiftUI

/// Editor/studio Help. Bundled copy — Help does not open the network (docs/14 UX-10, UX-28).
enum EditorHelpTopic: String, CaseIterable, Identifiable {
    case editor
    case arranging
    case export
    case studio
    case shortcuts

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .editor: String(localized: "Annotation editor")
        case .arranging: String(localized: "Selecting and arranging")
        case .export: String(localized: "Saving and sharing")
        case .studio: String(localized: "Recording studio")
        case .shortcuts: String(localized: "Keyboard shortcuts")
        }
    }

    /// The topic's paragraphs, each with a short heading (docs/18 §4.1 P3: Help used to be
    /// three paragraphs, and one of them named the wrong inspector shortcut).
    var sections: [EditorHelpSection] {
        switch self {
        case .editor: Self.editorSections
        case .arranging: Self.arrangingSections
        case .export: Self.exportSections
        case .studio: Self.studioSections
        case .shortcuts: Self.shortcutSections
        }
    }

    private static let editorSections = [
        EditorHelpSection(
            String(localized: "Annotations stay editable"),
            String(localized: """
            The capture underneath never changes. Every arrow, shape, text box and blur is an \
            object you can select, move, restyle or delete later, and undo goes back as far as \
            you need. The picture is flattened only when you copy, save or share it.
            """)
        ),
        EditorHelpSection(
            String(localized: "Tools"),
            String(localized: """
            Pick a tool from the toolbar or the Tools menu, or press its letter while the canvas \
            has the keyboard. After a one-shot tool lands — an arrow, a shape, a text box, a \
            blur — the pointer goes back to Select so you can move what you just drew. Pencil, \
            highlighter and counters stay armed. The inspector (⌥⌘I) holds the colour, size and \
            style of the selection or of the armed tool.
            """)
        ),
        EditorHelpSection(
            String(localized: "Blur, pixelate and erase"),
            String(localized: """
            Redactions are burned into the exported pixels, not laid over them, so nobody can \
            peel them off the file. A .kadr project keeps the original pixels so the redaction \
            stays editable; share the flattened image, not the project.
            """)
        ),
        EditorHelpSection(
            String(localized: "Lock objects"),
            String(localized: """
            ⇧⌘L locks the annotations already on the canvas, so drawing over them cannot move \
            them by accident. Commands that would change a locked object are greyed out until \
            you unlock.
            """)
        )
    ]

    private static let arrangingSections = [
        EditorHelpSection(
            String(localized: "Selecting"),
            String(localized: """
            Click to select, drag on empty canvas to select everything inside the box, ⌘-click \
            to add or remove one annotation and ⇧-click to add one. ⌘A selects everything.
            """)
        ),
        EditorHelpSection(
            String(localized: "Moving and snapping"),
            String(localized: """
            A moving selection snaps its edges and centre to the canvas and to other \
            annotations, and a guide line shows what it snapped to. Hold ⌘ while dragging to \
            place it freely. Arrow keys nudge by a point; a run of nudges undoes as one step. \
            ⌥-drag leaves the original where it is and drags a copy.
            """)
        ),
        EditorHelpSection(
            String(localized: "Align and distribute"),
            String(localized: """
            Edit ▸ Align lines the selection up on a shared edge or centre; a single annotation \
            aligns to the canvas. Distribute leaves equal gaps between three or more and keeps \
            the outermost two in place. Bring Forward (⌘]) and Send Backward (⌘[) change which \
            annotation is on top.
            """)
        )
    ]

    private static let exportSections = [
        EditorHelpSection(
            String(localized: "Copy"),
            String(localized: """
            ⌘C copies the image as you see it, annotations included. With annotations selected, \
            they are copied too, so pasting into another Kadr window gives editable objects. \
            Copy without annotations is in the toolbar's Copy menu.
            """)
        ),
        EditorHelpSection(
            String(localized: "Save"),
            String(localized: """
            ⌘S saves beside the capture, or over it when Keep the original file is off in \
            Settings ▸ General, and writes a .kadr project next to it so the capture stays \
            editable. ⇧⌘S chooses a format and quality. Move to Trash removes the capture and \
            its project together.
            """)
        ),
        EditorHelpSection(
            String(localized: "Share, pin and drag"),
            String(localized: """
            Share sends the flattened image through the macOS share sheet, and Pin floats it \
            above your windows. Dragging the file icon in the title bar hands the flattened \
            image to another app. Nothing is uploaded: Kadr never sends a capture anywhere.
            """)
        )
    ]

    private static let studioSections = [
        EditorHelpSection(
            String(localized: "Editing a recording"),
            String(localized: """
            The studio edits a copy of the timeline, never the recorded file. Split, trim and \
            delete clips on the timeline; add zooms that follow your clicks; crop and set a \
            backdrop. Undo covers every change.
            """)
        ),
        EditorHelpSection(
            String(localized: "Speech"),
            String(localized: """
            Transcribe makes a transcript and captions on this Mac. Find Cuts proposes pauses \
            and filler words to remove, and nothing is cut until you apply the proposal.
            """)
        ),
        EditorHelpSection(
            String(localized: "Exporting"),
            String(localized: """
            Export renders the current edit. Copy and Share render an MP4 up to 1080p; the \
            original recording is in the overflow menu. An export that fails or is cancelled \
            leaves any earlier file where it was.
            """)
        )
    ]

    private static let shortcutSections = [
        EditorHelpSection(
            String(localized: "Editor"),
            String(localized: """
            ⌘Z and ⇧⌘Z undo and redo. ⌘C copies, ⌘S saves, ⇧⌘S saves as, ⌥⌘S saves the \
            project. ⌥⌘I shows or hides the inspector. ⌘= and ⌘- zoom the canvas, ⌘1 fits it and \
            ⌘0 shows actual size. ⌘D duplicates the selection, Delete removes it. ` and + or - \
            change the armed tool's size.
            """)
        ),
        EditorHelpSection(
            String(localized: "Studio"),
            String(localized: """
            Space plays and pauses. J, K and L step back, stop and play; arrow keys move the \
            playhead, ⇧-arrows trim, ⌥-arrows take larger steps. ⌘K splits at the playhead. \
            Delete removes the selected clip or zoom, with Undo.
            """)
        )
    ]
}

/// One heading and its paragraph in Help.
struct EditorHelpSection: Identifiable {
    let heading: String
    let text: String

    var id: String {
        heading
    }

    init(_ heading: String, _ text: String) {
        self.heading = heading
        self.text = text
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
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(selection.sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.heading)
                                .font(.headline)
                            Text(section.text)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
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
        // An open Help window still turns to the topic asked for: it used to come forward on
        // whatever page it was last left at (docs/18 §4.1 P3).
        let hosting = NSHostingController(rootView: EditorHelpView(topic: topic))
        if let window {
            window.contentViewController = hosting
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Kadr Help")
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
