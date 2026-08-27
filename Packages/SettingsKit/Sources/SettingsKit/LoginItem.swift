import Foundation
import ServiceManagement
import Shared

/// The login-item state, mapped off `SMAppService.Status` (docs/04 §3.3).
public enum LoginItemState: Sendable, Equatable {
    /// Registered and will launch at login.
    case enabled
    /// Known to the system but not registered.
    case disabled
    /// Registered, but the user has to approve it in System Settings → Login Items.
    case requiresApproval
    /// The system has no record of the app — normal for an unsigned build run from
    /// DerivedData, and for a bundle that has never registered.
    case notFound

    public init(status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notRegistered: self = .disabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }

    /// What the General pane's toggle should show.
    public var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: true
        case .disabled, .notFound: false
        }
    }

    /// Explanation to show under the toggle, or `nil` when the state needs no words.
    public var explanation: String? {
        switch self {
        case .enabled, .disabled: nil
        case .requiresApproval: "Approve Kadr in System Settings → General → Login Items."
        case .notFound: "macOS has no record of this build. Move Kadr to /Applications and try again."
        }
    }
}

/// Launch-at-login, via `SMAppService.mainApp` (docs/04 §3.3 — no third-party helper).
///
/// The status is re-read on every launch and every time the Settings window opens,
/// because the user can flip it in System Settings behind the app's back.
@MainActor
@Observable
public final class LoginItemController {
    @ObservationIgnored private let service: SMAppService
    @ObservationIgnored private let logger = KadrLog.logger(.settings)

    public private(set) var state: LoginItemState

    public init(service: SMAppService = .mainApp) {
        self.service = service
        state = LoginItemState(status: service.status)
    }

    /// Re-reads the system's opinion. Cheap, event-driven, no polling (PRD §8).
    public func refresh() {
        state = LoginItemState(status: service.status)
    }

    public func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
        logger.info("Login item \(enabled ? "registered" : "unregistered", privacy: .public)")
    }
}
