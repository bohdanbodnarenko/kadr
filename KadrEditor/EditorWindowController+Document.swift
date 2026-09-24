import AppKit
import EditorUI

/// The File menu's document commands, on the window's own controller (T-ED-8).
///
/// They used to live on the app delegate, which picked "the key editor, or else the last
/// one" — so ⌘S in a Studio or Help window saved an annotation window the user could not
/// see. Here the responder chain decides: the items reach this object only while its window
/// is key, and grey out everywhere else.
extension EditorWindowController {
    @objc func saveDocument(_ sender: Any?) {
        export(.save)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        export(.saveAs)
    }

    @objc func saveProjectDocument(_ sender: Any?) {
        saveProject()
    }

    @objc func printDocument(_ sender: Any?) {
        export(.print)
    }

    @objc func copyFlattenedImage(_ sender: Any?) {
        export(.copyFlattened)
    }

    /// The one command that brings Finder forward; a save never does (T-ED-1).
    @objc func showInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([documentURL])
    }

    /// Whether a document command applies now.
    func validateDocumentCommand(_ action: Selector?) -> Bool? {
        switch action {
        case #selector(saveDocument(_:)),
             #selector(saveDocumentAs(_:)),
             #selector(printDocument(_:)),
             #selector(copyFlattenedImage(_:)):
            model.runningExport == nil
        case #selector(saveProjectDocument(_:)):
            true
        case #selector(showInFinder(_:)):
            FileManager.default.fileExists(atPath: documentURL.path) && !editsImportedCopy
        default:
            nil
        }
    }
}
