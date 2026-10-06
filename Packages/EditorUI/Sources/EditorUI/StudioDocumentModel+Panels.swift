import AppKit

@MainActor
extension StudioDocumentModel {
    /// Shows an open or save panel as a sheet on the studio window, and calls `chosen` with
    /// the picked file (docs/18 T-STU-12).
    ///
    /// The soundtrack and wallpaper panels used `runModal()`, which froze every other Kadr
    /// window — playback, the other studios, the annotation editor — until they closed. A
    /// sheet blocks only this window. With no window to hang from (a test, or a window that
    /// is closing) it opens as a free-standing panel, still without a modal loop.
    func presentPanel(_ panel: NSSavePanel, chosen: @escaping @MainActor (URL) -> Void) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { chosen(url) }
        }
        if let window = studioWindowContentView?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
