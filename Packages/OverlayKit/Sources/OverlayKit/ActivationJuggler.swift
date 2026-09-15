import AppKit
import Shared

/// The part of `NSApplication` the juggler needs, so the policy dance can be unit
/// tested without an `NSApplication` instance.
@MainActor
public protocol ActivationPolicyControlling: AnyObject {
    func currentActivationPolicy() -> NSApplication.ActivationPolicy
    @discardableResult func apply(_ policy: NSApplication.ActivationPolicy) -> Bool
    func activateApp()
}

extension NSApplication: ActivationPolicyControlling {
    public func currentActivationPolicy() -> NSApplication.ActivationPolicy {
        activationPolicy()
    }

    @discardableResult
    public func apply(_ policy: NSApplication.ActivationPolicy) -> Bool {
        setActivationPolicy(policy)
    }

    public func activateApp() {
        activate()
    }
}

/// The LSUIElement window recipe from docs/04 §3.1, in one place.
///
/// An `.accessory` app cannot reliably make a window key: it has no Dock presence to
/// activate through, so text fields do not take focus and ⌘W does nothing. The fix is
/// to become `.regular` for as long as a real window is on screen, then drop back to
/// `.accessory` so the agent leaves no Dock icon or menu bar behind.
///
/// Calls are reference counted, so two windows (say Settings and onboarding) cannot
/// leave the app stranded in `.regular` when only one of them closes.
@MainActor
public final class ActivationJuggler {
    public static let shared = ActivationJuggler(application: NSApplication.shared)

    private let application: any ActivationPolicyControlling
    private let idlePolicy: NSApplication.ActivationPolicy
    private let logger = KadrLog.logger(.overlay)

    public private(set) var regularWindowCount = 0

    public init(
        application: any ActivationPolicyControlling,
        idlePolicy: NSApplication.ActivationPolicy = .accessory
    ) {
        self.application = application
        self.idlePolicy = idlePolicy
    }

    /// Call before showing a window that needs to become key.
    public func beginRegularWindow() {
        regularWindowCount += 1
        guard regularWindowCount == 1 else { return }
        if application.currentActivationPolicy() != .regular {
            application.apply(.regular)
        }
        application.activateApp()
        logger.debug("Activation policy raised to .regular")
    }

    /// Call when that window has closed.
    ///
    /// The accessory drop is deferred by one turn so the Dock icon does not flicker as
    /// the last window's close animation finishes (docs/16 APP-P4).
    public func endRegularWindow() {
        guard regularWindowCount > 0 else {
            logger.error("endRegularWindow() called more times than beginRegularWindow()")
            return
        }
        regularWindowCount -= 1
        guard regularWindowCount == 0 else { return }
        Task { @MainActor in
            guard self.regularWindowCount == 0 else { return }
            self.application.apply(self.idlePolicy)
            self.logger.debug("Activation policy returned to idle")
        }
    }
}
