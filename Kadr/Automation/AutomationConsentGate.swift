import AppKit
import AutomationKit
import os
import OverlayKit
import SettingsKit
import Shared

/// Decides whether a `kadr://` request runs (docs/03 §8.4, docs/17 T-OUT-12).
///
/// The URL scheme is the one automation door any app can open, so it is the one that asks
/// who is knocking. The sender is read off the Apple event that delivered the URL — its
/// audit token where macOS provides one — and checked against `AutomationConsent`:
/// Kadr's own code runs, other apps need **Allow other apps to control Kadr** and a
/// per-app yes, and a sender that cannot be named is asked every time.
///
/// The CLI and the Shortcuts actions do not come through here: the CLI talks to the
/// message port, which checks the sender's code signature itself, and Shortcuts runs the
/// intents in-process after the user built the shortcut.
@MainActor
final class AutomationConsentGate {
    static let shared = AutomationConsentGate()

    let consent: AutomationConsent
    private let logger = KadrLog.logger(.app)

    init(consent: AutomationConsent = AutomationConsent()) {
        self.consent = consent
        // Every app that can open web links is a browser for this purpose, not only the
        // ones Kadr knows by name (docs/18 OUT-13).
        if let https = URL(string: "https://example.com") {
            let handlers = NSWorkspace.shared.urlsForApplications(toOpen: https)
                .compactMap { Bundle(url: $0)?.bundleIdentifier }
            consent.neverRemembered.formUnion(handlers)
        }
    }

    /// Who sent the Apple event being handled right now.
    static func currentSender() -> AutomationConsent.Sender {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return .unidentified(name: nil)
        }
        let peer: AutomationPeer
        if let token = event.attributeDescriptor(forKeyword: keySenderAuditTokenAttr),
           let fromToken = AutomationPeer(auditTokenData: token.data) {
            peer = fromToken
        } else if let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value, pid > 0 {
            peer = AutomationPeer(pid: pid)
        } else {
            return .unidentified(name: nil)
        }
        return sender(for: peer)
    }

    static func sender(for peer: AutomationPeer) -> AutomationConsent.Sender {
        if AutomationTrust.isTrusted(peer) {
            return .kadr
        }
        let app = NSRunningApplication(processIdentifier: peer.pid)
        guard let app, let bundleID = app.bundleIdentifier else {
            return .unidentified(name: app?.localizedName)
        }
        return .app(
            bundleID: bundleID,
            teamID: AutomationTrust.teamIdentifier(of: peer),
            name: app.localizedName ?? bundleID
        )
    }

    /// Runs `command` if the sender may, asking first when it has to.
    func authorize(
        _ command: AppCommand,
        from sender: AutomationConsent.Sender,
        openSettings: @escaping () -> Void,
        run: () -> Void
    ) {
        switch consent.verdict(for: sender) {
        case .run:
            run()
        case .ask:
            if ask(about: command, from: sender) {
                run()
            } else {
                logger.info("Automation request declined by the user")
            }
        case let .refuse(reason):
            refuse(command, from: sender, reason: reason, openSettings: openSettings)
        }
    }

    // MARK: - Private

    /// "Allow “Raycast” to control Kadr?" — asked once per app, or once per request for a
    /// sender with nothing to remember the answer against.
    private func ask(about command: AppCommand, from sender: AutomationConsent.Sender) -> Bool {
        let name = Self.displayName(of: sender)
        let alert = NSAlert()
        alert.alertStyle = .warning
        // What the request reaches, so the answer is about this file or region and not
        // only the verb (docs/18 OUT-13).
        let details = command.consentDetails.map { "• \($0)" }.joined(separator: "\n")
        let reach = details.isEmpty ? "" : "\n" + details
        if case .app = sender, consent.remembersAnswer(for: sender) {
            alert.messageText = String(localized: "Allow “\(name)” to control Kadr?")
            alert.informativeText = String(localized: """
            It asked Kadr to: \(command.verb.summary)\(reach)
            Apps you allow can take screenshots and recordings, and read files, with \
            Kadr's permissions. You can change this in Settings → Advanced.
            """)
            alert.addButton(withTitle: String(localized: "Don't Allow"))
            alert.addButton(withTitle: String(localized: "Allow"))
        } else if case .app = sender {
            // A browser opens kadr:// for whatever page it shows, so its yes holds for this
            // request only.
            alert.messageText = String(localized: "Allow “\(name)” to control Kadr this time?")
            alert.informativeText = String(localized: """
            A page in \(name) asked Kadr to: \(command.verb.summary)\(reach)
            Kadr asks every time for a web browser, because any website can make this request.
            """)
            alert.addButton(withTitle: String(localized: "Don't Allow"))
            alert.addButton(withTitle: String(localized: "Allow Once"))
        } else {
            alert.messageText = String(localized: "Allow this request to control Kadr?")
            alert.informativeText = String(localized: """
            \(name) asked Kadr to: \(command.verb.summary)\(reach)
            Kadr can't tell which app sent it, so it asks every time.
            """)
            alert.addButton(withTitle: String(localized: "Don't Allow"))
            alert.addButton(withTitle: String(localized: "Allow Once"))
        }
        // The safe answer is the default: Return must never grant screen access.
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""

        let allowed = ActivationJuggler.shared.withTemporaryActivation(
            returningTo: ActivationJuggler.returnTarget()
        ) { alert.runModal() } == .alertSecondButtonReturn
        consent.record(allowed ? .allowed : .denied, for: sender)
        return allowed
    }

    private func refuse(
        _ command: AppCommand,
        from sender: AutomationConsent.Sender,
        reason: AutomationConsent.RefusalReason,
        openSettings: @escaping () -> Void
    ) {
        let name = Self.displayName(of: sender)
        logger.info("Refused \(command.verb.rawValue, privacy: .public) from \(name, privacy: .public)")
        let message = switch reason {
        case .notAllowed: String(localized: "Kadr blocked a request from \(name)")
        case .deniedBefore: String(localized: "Kadr blocked \(name), which you didn't allow")
        }
        FailurePresenter.present(.failure(
            message,
            retryTitle: String(localized: "Settings…"),
            retry: openSettings
        ))
    }

    static func displayName(of sender: AutomationConsent.Sender) -> String {
        switch sender {
        case .kadr: "Kadr"
        case let .app(_, _, name): name
        case let .unidentified(name): name ?? String(localized: "An unknown app")
        }
    }
}
