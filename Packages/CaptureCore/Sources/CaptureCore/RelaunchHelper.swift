import AppKit
import Foundation
import os
import Shared

/// Restarts the app, because the first Screen Recording grant does not apply to the
/// process that asked for it (docs/04 §4.1).
///
/// macOS hands the running process a grant it cannot use: SCK keeps failing until the
/// app is launched again. Every screenshot tool hits this, and the ones that do not
/// automate it leave users convinced the app is broken.
public protocol ApplicationRelaunching: Sendable {
    /// Launches a second instance of the given bundle and returns once it is starting.
    func relaunch(bundleURL: URL) async throws
    /// Ends this instance.
    func terminate()
}

/// Relaunches through `NSWorkspace`, the only supported way to start an app bundle.
public struct WorkspaceRelauncher: ApplicationRelaunching {
    public init() {}

    public func relaunch(bundleURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        // Without this the existing (still running) instance is simply activated.
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
    }

    public func terminate() {
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }
}

/// Decides whether a relaunch is warranted and carries it out.
public struct RelaunchHelper: Sendable {
    private let relauncher: any ApplicationRelaunching
    private let bundleURL: URL
    private let logger = KadrLog.logger(.capture)

    public init(
        relauncher: any ApplicationRelaunching = WorkspaceRelauncher(),
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.relauncher = relauncher
        self.bundleURL = bundleURL
    }

    /// Restarts the app so the new grant takes effect.
    ///
    /// The new instance is started first and only then is this one told to quit, so a
    /// failure to launch leaves the user with a working app rather than none.
    public func relaunchForNewGrant() async throws {
        logger.info("Relaunching so the new screen recording grant takes effect")
        try await relauncher.relaunch(bundleURL: bundleURL)
        relauncher.terminate()
    }
}
