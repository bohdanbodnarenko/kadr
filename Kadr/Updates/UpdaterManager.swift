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
///
/// The controller is constructed in `start()`, after the launch interval closes, so Sparkle
/// is not mapped before the app can answer a hotkey. Automatic checks go through
/// `NSBackgroundActivityScheduler` so the OS coalesces them rather than leaving a repeating
/// timer in the resident process (docs/10 R2.3).
@MainActor
@Observable
final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()

    @ObservationIgnored private let logger = KadrLog.logger(.app)
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var activity: NSBackgroundActivityScheduler?
    @ObservationIgnored private var checkBackstopTask: Task<Void, Never>?

    /// Whether an update check can start right now — false while one is running.
    private(set) var canCheckForUpdates = false

    /// How long to hold the activation policy if Sparkle never reports back.
    private static let checkBackstopSeconds = 120
    /// Separate from Sparkle's `SUEnableAutomaticChecks` so disabling Sparkle's own timer
    /// does not forget the user's preference.
    private static let automaticChecksKey = "app.kadr.automaticUpdateChecks"

    override private init() {
        super.init()
    }

    /// Whoever is waiting for the current check to finish.
    private var checkFinishedWaiters: [CheckedContinuation<Void, Never>] = []

    private func setCanCheckForUpdates(_ value: Bool) {
        canCheckForUpdates = value
        guard value else { return }
        releaseCheckWaiters()
    }

    private func releaseCheckWaiters() {
        checkBackstopTask?.cancel()
        checkBackstopTask = nil
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
            checkBackstopTask?.cancel()
            checkBackstopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.checkBackstopSeconds))
                guard !Task.isCancelled else { return }
                self?.releaseCheckWaiters()
            }
        }
    }

    /// Whether Kadr checks for updates on its own.
    var automaticallyChecksForUpdates: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.automaticChecksKey) == nil {
                return UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
            }
            return UserDefaults.standard.bool(forKey: Self.automaticChecksKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.automaticChecksKey)
            if newValue {
                scheduleCoalescedCheck()
            } else {
                activity?.invalidate()
                activity = nil
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var lastUpdateCheckDate: Date? {
        controller?.updater.lastUpdateCheckDate
    }

    /// Starts the updater. Called once, after hotkeys are armed.
    func start() {
        #if DEBUG
            logger.info("Updates are disabled in debug builds")
        #else
            let created = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            controller = created
            canCheckObservation = created.updater.observe(
                \.canCheckForUpdates,
                options: [.initial, .new]
            ) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.setCanCheckForUpdates(updater.canCheckForUpdates)
                }
            }
            do {
                try created.updater.start()
                // Sparkle's repeating check is a timer in the resident process. Take it
                // off and ask the OS to coalesce a daily check instead (docs/10 R2.3).
                created.updater.automaticallyChecksForUpdates = false
                if automaticallyChecksForUpdates {
                    scheduleCoalescedCheck()
                }
                logger.info("Sparkle started")
            } catch {
                logger.error("Sparkle could not start: \(error.localizedDescription, privacy: .public)")
            }
        #endif
    }

    private func scheduleCoalescedCheck() {
        activity?.invalidate()
        let scheduler = NSBackgroundActivityScheduler(identifier: "app.kadr.Kadr.update-check")
        scheduler.repeats = true
        scheduler.interval = 24 * 60 * 60
        scheduler.tolerance = 6 * 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            MainActor.assumeIsolated {
                guard let self, self.automaticallyChecksForUpdates else {
                    completion(.finished)
                    return
                }
                self.controller?.updater.checkForUpdatesInBackground()
                completion(.finished)
            }
        }
        activity = scheduler
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
            guard let controller else { return }
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
