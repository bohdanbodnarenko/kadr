import Foundation

/// Where Help ▸ Report a Problem… sends the tester (docs/17 T-DIAG-1).
///
/// The app opens a page in the user's browser; it sends nothing itself, which is why this
/// is not a network exception (CLAUDE.md rule 1). Only non-identifying fields go into the
/// URL — version, build, commit and macOS — and the diagnostics zip is attached by hand,
/// after the user has had the chance to look inside it.
nonisolated enum ProblemReport {
    enum Destination: Equatable {
        /// A GitHub issue form, prefilled through its query parameters.
        case issueForm(String)
        /// For a private repository testers cannot open.
        case mail(String)
    }

    /// The public repository's issue form. Same owner/name as the appcast feed, so the two
    /// change together if the repository ever moves (docs/17 T-REL-4).
    static let destination = Destination.issueForm("https://github.com/bohdanbodnarenko/kadr/issues/new")

    /// The issue form's file name in `.github/ISSUE_TEMPLATE/`; its field ids are the
    /// query keys below.
    static let template = "bug.yml"

    static func url(
        for identity: BuildIdentity,
        macOS: String,
        destination: Destination = destination
    ) -> URL? {
        switch destination {
        case let .issueForm(base):
            var components = URLComponents(string: base)
            components?.queryItems = [
                URLQueryItem(name: "template", value: template),
                URLQueryItem(name: "labels", value: "dogfood"),
                URLQueryItem(name: "version", value: identity.version),
                URLQueryItem(name: "build", value: buildField(identity)),
                URLQueryItem(name: "os", value: macOS)
            ]
            return components?.url
        case let .mail(address):
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = address
            components.queryItems = [
                URLQueryItem(name: "subject", value: "Kadr \(identity.displayString): "),
                URLQueryItem(name: "body", value: mailBody(identity: identity, macOS: macOS))
            ]
            return components.url
        }
    }

    private static func buildField(_ identity: BuildIdentity) -> String {
        identity.commit.map { "\(identity.build) (\($0))" } ?? identity.build
    }

    private static func mailBody(identity: BuildIdentity, macOS: String) -> String {
        """
        Kadr \(identity.displayString) on macOS \(macOS)

        What I did:

        What I expected:

        What happened:

        (Please attach the diagnostics zip Kadr just showed in Finder.)
        """
    }
}
