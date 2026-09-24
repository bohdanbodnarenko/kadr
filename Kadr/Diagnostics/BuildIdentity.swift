import Foundation

/// Which build this is, precisely enough to find its source and its symbols
/// (docs/17 T-REL-5, T-REL-6).
///
/// Every build used to call itself "1.0 (1)", so two testers' reports could not be told
/// apart and neither could be matched to a dSYM. The build number is now the commit count
/// (monotonic, which Sparkle needs) and the commit is stamped into `KadrGitCommit` by the
/// Makefile and `Scripts/release.sh`.
nonisolated struct BuildIdentity: Equatable, Sendable {
    /// `CFBundleShortVersionString`, e.g. "0.9.0".
    let version: String
    /// `CFBundleVersion`, e.g. "512".
    let build: String
    /// The short SHA, or nil for a build nobody stamped (an Xcode-button build).
    let commit: String?

    static let commitKey = "KadrGitCommit"

    init(version: String, build: String, commit: String?) {
        self.version = version
        self.build = build
        self.commit = commit
    }

    /// Reads an Info dictionary, treating the project's "unknown" default and an
    /// unexpanded `$(…)` as no commit at all rather than printing either to a tester.
    init(infoDictionary info: [String: Any]) {
        version = (info["CFBundleShortVersionString"] as? String).nonEmpty ?? "—"
        build = (info["CFBundleVersion"] as? String).nonEmpty ?? "—"
        let raw = (info[Self.commitKey] as? String).nonEmpty
        commit = raw.flatMap { $0 == "unknown" || $0.contains("$(") ? nil : $0 }
    }

    static var current: BuildIdentity {
        BuildIdentity(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    /// "0.9.0 (512 · abc1234)", or "0.9.0 (512)" without a commit — what Settings, the
    /// About panel and a report all show, so a tester can read it out once.
    var displayString: String {
        if let commit {
            return "\(version) (\(build) · \(commit))"
        }
        return "\(version) (\(build))"
    }

    /// A pre-1.0 build is a dogfood build: it follows the beta channel by default.
    var isPrerelease: Bool {
        let major = version.split(separator: ".").first.flatMap { Int($0) }
        return major == 0
    }
}

private extension String? {
    nonisolated var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
