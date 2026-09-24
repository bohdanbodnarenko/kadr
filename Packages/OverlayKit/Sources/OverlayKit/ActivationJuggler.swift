import AppKit
import Shared

/// The part of `NSApplication` the juggler needs, so the policy dance can be unit
/// tested without an `NSApplication` instance.
@MainActor
public protocol ActivationPolicyControlling: AnyObject {
    func currentActivationPolicy() -> NSApplication.ActivationPolicy
    @discardableResult func apply(_ policy: NSApplication.ActivationPolicy) -> Bool
    func activateApp()
    /// Whether this app is the active one right now.
    var isActiveApp: Bool { get }
    /// Hands activation to `app` the cooperative macOS 14 way.
    func returnActivation(to app: NSRunningApplication)
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

    public var isActiveApp: Bool {
        isActive
    }

    /// `yieldActivation(to:)` then `activate(from:)`: the pair macOS 14 expects, so the
    /// hand-back is honoured rather than refused as focus stealing.
    public func returnActivation(to app: NSRunningApplication) {
        yieldActivation(to: app)
        app.activate(from: .current)
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

    // MARK: - Temporary activation (docs/17 §5 theme 1)

    /// Whether `bundleIdentifier` is an app Kadr may hand focus back to.
    ///
    /// Never Kadr itself or one of its sibling processes: "return to Kadr" is exactly the
    /// stale state that left the user's app unfocused after every island capture (T-CAP-3).
    public nonisolated static func isReturnable(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        return !bundleIdentifier.hasPrefix("app.kadr.")
    }

    /// The frontmost app right now, if Kadr may return focus to it.
    public static func returnTarget(
        _ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) -> NSRunningApplication? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              isReturnable(bundleIdentifier: app.bundleIdentifier) else { return nil }
        return app
    }

    /// Activates Kadr until the returned lease ends, then gives activation back.
    ///
    /// The one sanctioned way to activate the agent: a bare `NSApp.activate` has no
    /// matching hand-back, so the user's app is left inactive with no key window and the
    /// next keystroke beeps.
    public func beginTemporaryActivation(returningTo app: NSRunningApplication?) -> TemporaryActivation {
        application.activateApp()
        return TemporaryActivation(juggler: self, returnTo: app)
    }

    /// Activates Kadr for the duration of `body` — a modal alert or open panel — then
    /// returns activation to `app`.
    public func withTemporaryActivation<T>(
        returningTo app: NSRunningApplication?,
        _ body: () throws -> T
    ) rethrows -> T {
        let lease = beginTemporaryActivation(returningTo: app)
        defer { lease.end() }
        return try body()
    }

    /// Gives activation back to `app`, if Kadr holds it and `app` is somewhere to go.
    ///
    /// Does nothing while a regular window (Settings, onboarding) is open: that window is
    /// where the user is, and yielding would push it behind their other app.
    public func yieldActivation(to app: NSRunningApplication?) {
        guard let app, regularWindowCount == 0, application.isActiveApp,
              Self.isReturnable(bundleIdentifier: app.bundleIdentifier) else { return }
        application.returnActivation(to: app)
        logger.debug("Activation returned to the previous app")
    }
}

/// A span during which Kadr holds activation, from `beginTemporaryActivation`.
@MainActor
public final class TemporaryActivation {
    private weak var juggler: ActivationJuggler?
    /// Where activation goes when the lease ends.
    public let returnTo: NSRunningApplication?
    public private(set) var hasEnded = false

    init(juggler: ActivationJuggler, returnTo: NSRunningApplication?) {
        self.juggler = juggler
        self.returnTo = returnTo
    }

    /// Returns activation. Idempotent.
    public func end() {
        guard !hasEnded else { return }
        hasEnded = true
        juggler?.yieldActivation(to: returnTo)
    }

    /// Ends the lease without handing activation back: the caller passed focus on itself.
    public func abandon() {
        hasEnded = true
    }
}
