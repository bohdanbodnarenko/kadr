import Darwin
import Foundation
import Security

/// The process on the other end of an automation message (docs/17 T-OUT-12).
public struct AutomationPeer: Sendable {
    /// The kernel's record of the sender, from a Mach message's audit trailer or an Apple
    /// event's sender attribute. Unlike a PID, it names one process for its whole life and
    /// cannot be forged by the sender.
    public let auditToken: audit_token_t?
    /// The sender's process ID. Used for trust only when no audit token is available.
    public let pid: pid_t

    public init(auditToken: audit_token_t) {
        self.auditToken = auditToken
        // `audit_token_to_pid` lives in libbsm; the PID is the token's sixth word.
        pid = pid_t(bitPattern: auditToken.val.5)
    }

    /// From an audit token's raw bytes, as an Apple event carries it.
    public init?(auditTokenData data: Data) {
        guard data.count == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { data.copyBytes(to: $0) }
        self.init(auditToken: token)
    }

    public init(pid: pid_t) {
        auditToken = nil
        self.pid = pid
    }

    var guestAttributes: CFDictionary {
        if let auditToken {
            return [kSecGuestAttributeAudit: withUnsafeBytes(of: auditToken) { Data($0) }] as CFDictionary
        }
        return [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
    }
}

/// Who may send the agent commands over the message port (docs/17 T-OUT-12).
///
/// The port is how the bundled `kadr` CLI and the editor reach the agent. Anything else
/// that can look the port up — any process the user runs — could otherwise drive captures
/// through Kadr's Screen Recording grant: a confused deputy. So a sender must be code
/// signed by the same team as Kadr itself, checked against its audit token.
///
/// A development build signed ad hoc has no team to compare. There, the sender must be
/// running from inside Kadr's own bundle, which is where the CLI and the editor ship.
public enum AutomationTrust {
    public static func isTrusted(_ peer: AutomationPeer) -> Bool {
        if peer.pid == getpid() {
            return true
        }
        guard let code = guestCode(for: peer) else { return false }
        if let team = ownTeamIdentifier {
            return satisfies(code, requirement: "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        }
        guard let path = path(of: code) else { return false }
        return isInsideBundle(path)
    }

    /// This process's signing team, or nil for an ad-hoc or unsigned build.
    static let ownTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return teamIdentifier(of: code)
    }()

    /// The sender's signing team, or nil when it is unsigned or ad hoc. Part of how a
    /// remembered consent is keyed, so an impostor cannot borrow another app's answer.
    public static func teamIdentifier(of peer: AutomationPeer) -> String? {
        guestCode(for: peer).flatMap(teamIdentifier(of:))
    }

    static func guestCode(for peer: AutomationPeer) -> SecCode? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, peer.guestAttributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    static func satisfies(_ code: SecCode, requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func teamIdentifier(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let info = info as? [String: Any]
        else {
            return nil
        }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func path(of code: SecCode) -> URL? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return url as URL
    }

    /// Inside this app's bundle — where the CLI and the editor both ship.
    static func isInsideBundle(_ path: URL, bundle: URL = Bundle.main.bundleURL) -> Bool {
        let root = bundle.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return path.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
    }
}
