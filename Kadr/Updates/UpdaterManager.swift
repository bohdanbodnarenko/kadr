import AppKit
import os
import OverlayKit
import Shared
import Sparkle

/// Sparkle, and the only networking Kadr ever does (PRD §4, §9, docs/04 §10).
///
/// This file is the single exception to the zero-network rule, and it lives in the one
/// directory `Scripts/check-layering.sh` allows networking symbols in. There is no upload
/// feature, no telemetry and no share-by-URL anywhere else in the app — that is the
/// promise the layering check exists to keep honest.
///
/// Updates are on by default with a visible switch, which is what the PRD asks for: the
/// user can see the one thing that talks to the network and turn it off.
@MainActor
@Observable
final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()

    @ObservationIgnored private let logger = KadrLog.logger(.app)
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// Whether an update check can start right now — false while one is running.
    private(set) var canCheckForUpdates = false

    override private init() {
        // Started explicitly in `start()` rather than here, so launch controls when the
        // first network call can happen — and so debug builds can decline entirely.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Whether Kadr checks for updates on its own.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    /// Starts the updater. Called once, at launch.
    func start() {
        #if DEBUG
            // A debug build must never offer to replace itself with a release one.
            logger.info("Updates are disabled in debug builds")
        #else
            do {
                try controller.updater.start()
                logger.info("Sparkle started")
            } catch {
                logger.error("Sparkle could not start: \(error.localizedDescription, privacy: .public)")
            }
        #endif
    }

    /// The menu command.
    ///
    /// An `.accessory` app cannot show Sparkle's window properly, so this borrows the
    /// same activation dance Settings uses (docs/04 §3.1) instead of leaving the update
    /// sheet stranded behind whatever the user is doing.
    func checkForUpdates() {
        #if DEBUG
            logger.info("Ignoring an update check in a debug build")
        #else
            ActivationJuggler.shared.beginRegularWindow()
            controller.checkForUpdates(nil)
            // Sparkle's window has no close callback to hook, so the policy is released
            // once the check can start again — which is when its UI has gone.
            Task { @MainActor [weak self] in
                while self?.canCheckForUpdates == false {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                ActivationJuggler.shared.endRegularWindow()
            }
        #endif
    }
}
