import AppKit
import HistoryKit
import os
import OverlayKit
import Shared
import SwiftUI

/// Owns the History window (docs/03 §5).
///
/// Built on demand and torn down on close, same recipe as Settings: SwiftUI lives only
/// while the window is open so the agent returns to its idle footprint (PRD §8).
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let controller: HistoryController
    private let reopen: (HistoryRecord) -> Void
    private let openStudio: (HistoryRecord) -> Void
    private let juggler: ActivationJuggler
    private let logger = KadrLog.logger(.history)

    private(set) var window: NSWindow?
    private weak var hostingView: NSView?

    init(
        controller: HistoryController,
        reopen: @escaping (HistoryRecord) -> Void,
        openStudio: @escaping (HistoryRecord) -> Void,
        juggler: ActivationJuggler = .shared
    ) {
        self.controller = controller
        self.reopen = reopen
        self.openStudio = openStudio
        self.juggler = juggler
    }

    var isOpen: Bool {
        window != nil
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(
            rootView: HistoryView(controller: controller, open: openStudio, openAsCard: reopen)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.contentView = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("app.kadr.Kadr.history")
        window.minSize = HistoryWindowGeometry.minimumSize

        self.window = window
        hostingView = hosting

        juggler.beginRegularWindow()
        window.makeKeyAndOrderFront(nil)
        logger.info("History window opened")
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        window.delegate = nil
        window.contentView = nil
        self.window = nil
        controller.cache.removeAll()
        juggler.endRegularWindow()
        logger.info("History window closed")
        assertTornDown()
    }

    private func assertTornDown() {
        let hosting = hostingView
        hostingView = nil
        #if DEBUG
            Task { @MainActor [weak hosting] in
                for _ in 0 ..< 20 {
                    if hosting == nil {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                assert(hosting == nil, "History hosting view leaked — check for a retain cycle")
            }
        #endif
    }
}
