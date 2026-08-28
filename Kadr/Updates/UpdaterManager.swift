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

    /// How long to hold the activation policy if Sparkle never reports back.
    private static let checkBackstopSeconds = 120

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
                self?.setCanCheckForUpdates(updater.canCheckForUpdates)
            }
        }
    }

    /// Whoever is waiting for the current check to finish.
    private var checkFinishedWaiters: [CheckedContinuation<Void, Never>] = []

    private func setCanCheckForUpdates(_ value: Bool) {
        canCheckForUpdates = value
        guard value else { return }
        releaseCheckWaiters()
    }

    private func releaseCheckWaiters() {
        guard !checkFinishedWaiters.isEmpty else { return }
        let waiting = checkFinishedWaiters
        checkFinishedWaiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
    }

    /// Waits for the running check to finish, without asking every half second.
    ///
    /// Sparkle reports through KVO, so there is an event to wait on; polling for it was
    /// the agent doing work on a schedule for no reason (docs/07 LOW, CLAUDE.md rule 2).
    /// The backstop exists because the activation policy must not be stuck regular for the
    /// rest of the session if Sparkle never reports — and because an unresumed
    /// continuation is a leak, not a timeout.
    private func waitForCheckToFinish() async {
        await withCheckedContinuation { continuation in
            checkFinishedWaiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.checkBackstopSeconds))
                self?.releaseCheckWaiters()
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
                guard let self else {
                    ActivationJuggler.shared.endRegularWindow()
                    return
                }
                await waitForCheckToFinish()
                ActivationJuggler.shared.endRegularWindow()
            }
        #endif
    }
}
