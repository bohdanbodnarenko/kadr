import AppKit
import OverlayKit
import SwiftUI

/// The agent Help window. Built on demand and torn down on close (PRD §8).
@MainActor
final class KadrHelpWindowController: NSObject, NSWindowDelegate {
    static let shared = KadrHelpWindowController()

    private var window: NSWindow?
    private let juggler = ActivationJuggler.shared

    func show(topic: KadrHelpTopic = .shortcuts) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: KadrHelpView(topic: topic))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Kadr Help"
        window.contentViewController = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        juggler.beginRegularWindow()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window?.contentViewController = nil
        window = nil
        juggler.endRegularWindow()
    }
}
