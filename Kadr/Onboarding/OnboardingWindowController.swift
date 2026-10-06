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

    /// Fired when the welcome closes and is not waiting on a relaunch.
    var onClosed: (() -> Void)?

    init(model: OnboardingModel, settings: AppSettings, juggler: ActivationJuggler = .shared) {
        self.model = model
        self.settings = settings
        self.juggler = juggler
        super.init()
        model.onFinish = { [weak self] in self?.close() }
    }

    /// - Parameter step: where to open when the window is not already up. `nil` resumes
    ///   at Permissions after a relaunch and starts at Welcome otherwise.
    func show(startingAt step: OnboardingStep? = nil) {
        if let window {
            // Activates and deminiaturizes too: a second request for an open window used
            // to order it front behind the app the user was in (docs/17 T-SH-5).
            juggler.bringForward(window)
            return
        }

        if let step {
            model.step = step
        } else if settings.resumeOnboardingAtPermissions {
            model.step = .permissions
        } else {
            model.step = .welcome
        }

        let hosting = NSHostingView(rootView: OnboardingView(model: model, settings: settings))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to Kadr")
        window.contentView = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = UXLayoutContract.onboardingMinimum
        window.center()

        self.window = window
        hostingView = hosting
        juggler.beginRegularWindow()
        window.makeKeyAndOrderFront(nil)
        if model.step == .permissions {
            model.startWatchingForGrant()
        }
    }

    /// Closes for real. `close()` rather than `performClose(_:)` on purpose: this is
    /// called *after* the explanation has been accepted, and `performClose` would send it
    /// back through `windowShouldClose` and ask again (docs/14 UX-07).
    func close() {
        window?.close()
    }

    /// The red close button gets the same explanation Escape does (docs/14 UX-07).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.requiresCloseExplanation else { return true }
        model.requestClose()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.stopWatchingForGrant()
        // A relaunch for a new grant must keep the resume flag. Any other close is a
        // skip, so setup never nags next launch (docs/03 §8.2).
        if settings.resumeOnboardingAtPermissions, model.needsRelaunch {
            logger.info("Keeping onboarding paused on permissions across relaunch")
        } else {
            settings.resumeOnboardingAtPermissions = false
            if !settings.hasCompletedOnboarding {
                settings.hasCompletedOnboarding = true
            }
            onClosed?()
        }
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
