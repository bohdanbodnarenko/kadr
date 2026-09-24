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
/// The controller is constructed only when a check actually runs — inside the coalesced
/// background activity, or when the user picks "Check for Updates…" — so an idle agent
/// never maps Sparkle's updater or its UI driver (PRD §8). Automatic checks go through
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
    /// Whether this manager currently holds the regular activation policy for Sparkle's
    /// window, so a session that ends twice cannot release it twice.
    @ObservationIgnored private var holdsActivation = false

    /// Whether an update check can start right now — false while one is running.
    private(set) var canCheckForUpdates = false

    /// A scheduled check found this version while Kadr was in the background, and Sparkle
    /// left it to Kadr to mention gently rather than throwing a window over whatever the
    /// user was doing (docs/17 T-REL-4). The status menu offers it until the session ends.
    private(set) var availableUpdateVersion: String?

    /// Whether beta builds are offered too. Stored so SwiftUI tracks it; the preference is
    /// the source of truth across launches.
    var receivesBetaBuilds: Bool {
        didSet {
            channelPreference.receivesBetaBuilds = receivesBetaBuilds
            logger.notice("Beta updates \(self.receivesBetaBuilds ? "on" : "off", privacy: .public)")
        }
    }

    /// Sparkle's record of its last check, read directly so Settings can show it without
    /// building the updater.
    private static let lastCheckTimeKey = "SULastCheckTime"
    /// Separate from Sparkle's `SUEnableAutomaticChecks` so disabling Sparkle's own timer
    /// does not forget the user's preference.
    @ObservationIgnored private let preference = UpdateCheckPreference(defaults: .standard)
    @ObservationIgnored private let channelPreference = UpdateChannelPreference(
        defaults: .standard,
        build: .current
    )

    override private init() {
        receivesBetaBuilds = channelPreference.receivesBetaBuilds
        automaticallyChecksForUpdates = UpdateCheckPreference(defaults: .standard).isEnabled
        super.init()
    }

    private func setCanCheckForUpdates(_ value: Bool) {
        canCheckForUpdates = value
    }

    /// Raises the activation policy so Sparkle's window comes to the front.
    ///
    /// An `.accessory` app's windows open behind whatever is frontmost. Held from the moment
    /// Sparkle says it will show something until it says the session is over — its own
    /// callbacks, rather than the 120-second guess this used to be (docs/17 T-REL-4).
    private func holdActivation() {
        guard !holdsActivation else { return }
        holdsActivation = true
        ActivationJuggler.shared.beginRegularWindow()
    }

    private func releaseActivation() {
        guard holdsActivation else { return }
        holdsActivation = false
        ActivationJuggler.shared.endRegularWindow()
    }

    /// Whether Kadr checks for updates on its own.
    ///
    /// Stored, so SwiftUI observes it: it used to be computed from `UserDefaults`, which
    /// `@Observable` cannot see, so the switch did not follow a change made elsewhere
    /// (docs/16 APP-P1, docs/17 T-SH-8).
    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            preference.isEnabled = automaticallyChecksForUpdates
            #if !DEBUG
                if automaticallyChecksForUpdates {
                    scheduleCoalescedCheck()
                } else {
                    activity?.invalidate()
                    activity = nil
                }
            #endif
        }
    }

    /// False in a debug build, which never talks to the feed; Settings says so rather than
    /// showing a Check Now that silently does nothing (docs/17 T-SH-8).
    var isUpdatingAvailable: Bool {
        #if DEBUG
            false
        #else
            true
        #endif
    }

    /// Which build this is, for Settings ▸ Updates and diagnostics (docs/17 T-REL-5).
    var buildIdentity: BuildIdentity {
        .current
    }

    private(set) var lastCheckDate: Date?

    var lastUpdateCheckDate: Date? {
        lastCheckDate
            ?? controller?.updater.lastUpdateCheckDate
            ?? UserDefaults.standard.object(forKey: Self.lastCheckTimeKey) as? Date
    }

    /// Arms automatic checks. Called once, after hotkeys are armed.
    ///
    /// Builds nothing from Sparkle: that waits for the first check that actually runs.
    func start() {
        #if DEBUG
            logger.info("Updates are disabled in debug builds")
        #else
            preference.migrateIfNeeded()
            // No check is running, so one may start — the menu offers the command without
            // the updater having been built to say so.
            setCanCheckForUpdates(true)
            if automaticallyChecksForUpdates {
                scheduleCoalescedCheck()
            }
        #endif
    }

    /// The Sparkle controller, built and started on first use.
    private func updaterController() -> SPUStandardUpdaterController? {
        #if DEBUG
            return nil
        #else
            if let controller {
                return controller
            }
            let created = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            // Before `start()`: Sparkle's repeating check is a timer in the resident
            // process, and an explicit value here also keeps it from asking the user a
            // permission question Kadr's own switch already answers (docs/10 R2.3). This
            // persists `SUEnableAutomaticChecks = false`, which is why Kadr never reads
            // that key back (`UpdateCheckPreference`).
            created.updater.automaticallyChecksForUpdates = false
            canCheckObservation = created.updater.observe(
                \.canCheckForUpdates,
                options: [.new]
            ) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.setCanCheckForUpdates(updater.canCheckForUpdates)
                    self?.lastCheckDate = updater.lastUpdateCheckDate
                }
            }
            do {
                try created.updater.start()
                controller = created
                logger.notice("Sparkle started")
                return created
            } catch {
                canCheckObservation = nil
                logger.error("Sparkle could not start: \(error.localizedDescription, privacy: .public)")
                return nil
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
        // The block arrives on a queue of the scheduler's choosing, not the main thread,
        // so it hops rather than assuming isolation.
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                self?.runBackgroundCheck()
                completion(.finished)
            }
        }
        activity = scheduler
    }

    private func runBackgroundCheck() {
        guard automaticallyChecksForUpdates else { return }
        logger.notice("Scheduled update check")
        updaterController()?.updater.checkForUpdatesInBackground()
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
            guard let controller = updaterController() else { return }
            logger.notice("Update check requested")
            // Before the call: Sparkle's "Checking…" window appears straight away, and it
            // should appear in front. Released in `standardUserDriverWillFinishUpdateSession`.
            holdActivation()
            controller.checkForUpdates(nil)
        #endif
    }
}

// MARK: - Channels (docs/17 T-REL-4)

extension UpdaterManager: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channelPreference.allowedChannels
    }
}

// MARK: - Gentle reminders for a background app

/// Sparkle's guidance for apps without a Dock icon: a scheduled check that finds an update
/// while the app is not in focus should not throw a window in front of the user's work,
/// nor open one behind it where it is never seen. Kadr lets Sparkle show it only when the
/// user is already looking at Kadr, and otherwise offers it in the status menu.
extension UpdaterManager: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            holdActivation()
        } else {
            availableUpdateVersion = update.displayVersionString
            let version = update.displayVersionString
            logger.notice("Update \(version, privacy: .public) is available; offered in the menu")
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableUpdateVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdateVersion = nil
        releaseActivation()
    }
}
