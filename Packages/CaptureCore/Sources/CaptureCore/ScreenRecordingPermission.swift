import CoreGraphics
import Foundation
import os
import Shared

/// The Screen Recording grant, as a state machine (docs/04 §4.1).
public enum ScreenRecordingPermission: String, Sendable, CaseIterable {
    /// Not asked yet in this process.
    case unknown
    /// macOS says no. The user has never granted, or granted and then removed it.
    case denied
    /// Capture works.
    case granted
    /// It worked, and then a capture came back declined — the macOS 15 re-approval
    /// lapse looks exactly like this.
    case revoked

    /// Whether capture can be attempted.
    public var allowsCapture: Bool {
        self == .granted
    }

    /// Whether the user has to do something in System Settings before capture works.
    public var needsUserAction: Bool {
        self == .denied || self == .revoked
    }
}

/// The three system calls the permission machine depends on, behind a protocol so the
/// state transitions can be tested without a TCC database.
public protocol ScreenRecordingAccessProviding: Sendable {
    /// `CGPreflightScreenCaptureAccess` — asks without prompting.
    func preflight() -> Bool
    /// `CGRequestScreenCaptureAccess` — prompts the first time, no-ops afterwards.
    @discardableResult func request() -> Bool
    /// Silent live check, polled only while onboarding is on screen.
    ///
    /// Must not call ScreenCaptureKit: `SCShareableContent` presents the
    /// "record this computer's screen and audio" sheet on macOS 15+, and a
    /// one-second loop re-presents it even when the System Settings toggle is
    /// already on (docs/04 §4.1).
    func probe() async -> Bool
}

/// The real implementation, talking to CoreGraphics. ScreenCaptureKit is not used
/// here: asking for shareable content is a prompt on macOS 15+, not a check.
public struct SystemScreenRecordingAccess: ScreenRecordingAccessProviding {
    public init() {}

    public func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func probe() async -> Bool {
        preflight()
    }
}

/// Owns the permission state and every transition into it (docs/04 §4.1).
///
/// Two rules shape this type:
///
/// * **Nothing polls except onboarding.** A background poll would be a timer, and the
///   agent's idle budget is zero timers (PRD §8). Everywhere else the state moves in
///   response to something: a capture succeeding, a capture failing, the user pressing
///   a button.
/// * **The first grant needs a relaunch.** macOS hands an already-running process a
///   grant it cannot use, so onboarding has to restart the app. That is tracked here
///   rather than guessed at by the UI.
@MainActor
@Observable
public final class PermissionCoordinator {
    @ObservationIgnored private let access: any ScreenRecordingAccessProviding
    @ObservationIgnored private let logger = KadrLog.logger(.capture)
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    public private(set) var state: ScreenRecordingPermission = .unknown

    /// True when the grant arrived while this process was already running, so the
    /// running process still cannot capture until it restarts.
    public private(set) var needsRelaunchAfterGrant = false

    /// Whether the onboarding probe loop is running. It is the only poll in the app.
    public var isProbing: Bool {
        probeTask != nil
    }

    public init(access: any ScreenRecordingAccessProviding = SystemScreenRecordingAccess()) {
        self.access = access
    }

    deinit {
        probeTask?.cancel()
    }

    /// Reads the current grant without prompting. Safe to call at launch.
    @discardableResult
    public func refresh() -> ScreenRecordingPermission {
        let granted = access.preflight()
        if granted {
            // Granted before we launched, so this process can capture right now.
            transition(to: .granted, viaProbe: false)
        } else if state != .revoked {
            transition(to: .denied, viaProbe: false)
        }
        return state
    }

    /// Shows the system prompt the first time, and opens nothing afterwards.
    ///
    /// macOS only ever prompts once per app; later calls return the stored answer, which
    /// is why onboarding has to deep-link into System Settings as well.
    @discardableResult
    public func requestAccess() -> Bool {
        let granted = access.request()
        if granted {
            transition(to: .granted, viaProbe: true)
        }
        return granted
    }

    /// Starts the onboarding-only probe loop.
    ///
    /// This is the single polling loop in the app and it exists because macOS gives no
    /// notification when the user flips the switch in System Settings. It must be
    /// stopped when the onboarding window closes.
    public func beginProbing(every interval: Duration = .seconds(1)) {
        guard probeTask == nil else { return }
        logger.info("Started onboarding permission probe")
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await access.probe() {
                    transition(to: .granted, viaProbe: true)
                    endProbing()
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stops the probe loop. Always called when onboarding goes away.
    public func endProbing() {
        guard let probeTask else { return }
        probeTask.cancel()
        self.probeTask = nil
        logger.info("Stopped onboarding permission probe")
    }

    /// Feeds a capture failure back into the state machine.
    ///
    /// Errors that are not about permission leave the state alone — a window closing
    /// mid-capture must not tell the user their grant was revoked.
    public func noteCaptureFailure(_ error: any Error) {
        let captureError = CaptureError.mapping(error)
        guard captureError.indicatesPermissionLoss else { return }
        transition(to: state == .unknown ? .denied : .revoked, viaProbe: false)
    }

    /// A capture worked, so whatever we believed about the grant, it is live.
    public func noteCaptureSuccess() {
        guard state != .granted else { return }
        transition(to: .granted, viaProbe: true)
    }

    /// Called once the app has restarted with the grant in place.
    public func clearRelaunchRequirement() {
        needsRelaunchAfterGrant = false
    }

    private func transition(to newState: ScreenRecordingPermission, viaProbe: Bool) {
        guard newState != state else { return }
        let previous = state
        state = newState
        if newState == .granted, viaProbe, previous != .unknown {
            // The grant landed mid-process; this instance still cannot use it.
            needsRelaunchAfterGrant = true
        }
        let from = previous.rawValue
        let to = newState.rawValue
        logger.info("Screen recording permission \(from, privacy: .public) → \(to, privacy: .public)")
    }
}
