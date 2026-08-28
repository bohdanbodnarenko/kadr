import AutomationKit
import Foundation

/// Settings an automated capture may override for one shot (docs/03 §8.4).
///
/// Every field is optional and every `nil` means "use the setting". A URL that says
/// nothing about the cursor must not quietly turn it on, and one that says `action=copy`
/// must not permanently change the user's default — so overrides live for exactly one
/// capture and are cleared when it reports back.
struct CaptureOverrides: Sendable, Equatable {
    var action: CaptureAction?
    var delaySeconds: Int?
    var includesCursor: Bool?

    static let none = CaptureOverrides()

    var isEmpty: Bool {
        self == .none
    }

    init(action: CaptureAction? = nil, delaySeconds: Int? = nil, includesCursor: Bool? = nil) {
        self.action = action
        self.delaySeconds = delaySeconds
        self.includesCursor = includesCursor
    }

    init(_ options: CaptureOptions) {
        self.init(
            action: options.action,
            delaySeconds: options.delay,
            includesCursor: options.includesCursor
        )
    }
}

/// How a capture that automation asked for ended.
///
/// The URL scheme throws this away; the CLI turns it into stdout and an exit code, and
/// Shortcuts turns it into a file the next action can consume.
enum CaptureOutcome: Sendable, Equatable {
    case file(URL)
    case text(String)
    case cancelled
    case failed(String)

    var response: AutomationResponse {
        switch self {
        case let .file(url): .file(url.path)
        case let .text(text): AutomationResponse(status: .ok, text: text)
        case .cancelled: .cancelled
        case let .failed(message): .failed(message)
        }
    }
}
