import AppKit
import OverlayKit
import SwiftUI

/// The agent Help window. Built on demand and torn down on close (PRD §8).
@MainActor
final class KadrHelpWindowController: NSObject, NSWindowDelegate {
    static let shared = KadrHelpWindowController()

    private var window: NSWindow?
    private var navigation: KadrHelpNavigation?
    private let juggler = ActivationJuggler.shared

    func show(topic: KadrHelpTopic = .gettingStarted) {
        if let window, let navigation {
            navigation.selection = topic
            juggler.bringForward(window)
            return
        }

        let navigation = KadrHelpNavigation(selection: topic)
        self.navigation = navigation
        let hosting = NSHostingController(rootView: KadrHelpView(navigation: navigation))
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
        navigation = nil
        juggler.endRegularWindow()
    }
}
