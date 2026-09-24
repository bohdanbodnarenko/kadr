import AppKit
import EditorUI

/// The Clip menu's commands (T-ED-2).
///
/// The studio's edits were reachable only from the transport bar and bare keys, so menu
/// search could not find them and nothing in the menu bar said they existed. Each item
/// calls the same model action the button or key does; nothing new happens here.
extension StudioWindowController {
    /// Whether the timeline can be edited: not while cropping owns the preview, and not
    /// while an export is reading the edit.
    private var acceptsClipCommands: Bool {
        !model.isCropping && model.exportProgress == nil
    }

    @objc func togglePlayback(_ sender: Any?) {
        guard acceptsClipCommands else { return }
        model.togglePlayback()
    }

    @objc func trimStartToPlayhead(_ sender: Any?) {
        guard acceptsClipCommands else { return }
        model.trimStartToPlayhead()
    }

    @objc func trimEndToPlayhead(_ sender: Any?) {
        guard acceptsClipCommands else { return }
        model.trimEndToPlayhead()
    }

    @objc func addZoomAtPlayhead(_ sender: Any?) {
        guard acceptsClipCommands else { return }
        model.addZoom()
    }

    @objc func deleteTimelineSelection(_ sender: Any?) {
        guard acceptsClipCommands else { return }
        model.deleteTimelineSelection()
    }
}
