import AppKit
import CaptureCore
import os
import OverlayKit
import SettingsKit
import Shared
import SwiftUI

/// Hosts onboarding in a real window (docs/03 §8.2).
///
/// Same `ActivationJuggler` dance as Settings: an `.accessory` app cannot make a window
/// key on its own, and an onboarding screen the user cannot type into is worse than none.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: OnboardingModel
    private let settings: AppSettings
    private let juggler: ActivationJuggler
    private let logger = KadrLog.logger(.app)

    private var window: NSWindow?
    private weak var hostingView: NSView?

    var isOpen: Bool {
        window != nil
    }

    init(model: OnboardingModel, settings: AppSettings, juggler: ActivationJuggler = .shared) {
        self.model = model
        self.settings = settings
        self.juggler = juggler
        super.init()
        model.onFinish = { [weak self] in self?.close() }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(rootView: OnboardingView(model: model, settings: settings))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Kadr"
        window.contentView = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        hostingView = hosting
        juggler.beginRegularWindow()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopWatchingForGrant()
        window?.delegate = nil
        window?.contentView = nil
        window = nil
        juggler.endRegularWindow()

        #if DEBUG
            Task { @MainActor [weak hosting = hostingView] in
                for _ in 0 ..< 20 {
                    if hosting == nil {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                assert(hosting == nil, "Onboarding view leaked — check for a retain cycle")
            }
        #endif
        hostingView = nil
    }
}
