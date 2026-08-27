import AppKit
import Foundation

/// Supplies the app that is in front, so captures can be named after it.
///
/// Behind a protocol because `NSWorkspace` is main-actor-only and untestable, and
/// because the interesting call site — the selection overlay — needs the app that was
/// frontmost at *hotkey* time, not at capture time.
public protocol FrontmostApplicationProviding: Sendable {
    func currentApplication() async -> AppIdentity?
}

/// Reads the frontmost app from `NSWorkspace`.
public struct WorkspaceFrontmostApplication: FrontmostApplicationProviding {
    public init() {}

    public func currentApplication() async -> AppIdentity? {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return AppIdentity(name: app.localizedName, bundleIdentifier: app.bundleIdentifier)
        }
    }
}

/// An identity fixed at construction, for replaying the app that was frontmost when a
/// hotkey fired, and for tests.
public struct FixedFrontmostApplication: FrontmostApplicationProviding {
    private let identity: AppIdentity?

    public init(_ identity: AppIdentity?) {
        self.identity = identity
    }

    public func currentApplication() async -> AppIdentity? {
        identity
    }
}
