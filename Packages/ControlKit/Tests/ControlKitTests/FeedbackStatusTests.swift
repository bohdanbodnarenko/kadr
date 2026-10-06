import ControlKit
import Testing

/// The shared feedback model (docs/18 X-2).
@Suite("Feedback status")
struct FeedbackStatusTests {
    @Test("Each kind has its own symbol, and only failures and warnings stay", arguments: [
        (FeedbackKind.progress, "ellipsis.circle", false),
        (.completion, "checkmark.circle.fill", false),
        (.warning, "exclamationmark.triangle.fill", true),
        (.error, "xmark.octagon.fill", true)
    ])
    func kinds(kind: FeedbackKind, symbol: String, stays: Bool) {
        #expect(kind.symbolName == symbol)
        #expect(kind.staysUntilDismissed == stays)
    }

    @Test("Completions dismiss themselves; failures wait")
    func dismissal() {
        #expect(FeedbackStatus.done("Copied").autoDismissDelay == .seconds(3))
        #expect(FeedbackStatus.failure("No").autoDismissDelay == nil)
        #expect(FeedbackStatus.undoable("Trashed") {}.autoDismissDelay == FeedbackStatus.undoWindow)
    }
}
