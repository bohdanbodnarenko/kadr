import Foundation
import RecordingCore
import Testing
@testable import Kadr

/// The state a recording is in, and what that permits (docs/10 R0.3).
///
/// Its own suite because the hazard is a gap in time rather than a wrong value. Starting a
/// capture is several hundred milliseconds of asking ScreenCaptureKit for permission,
/// content and a stream; for the whole of that window the app used to report itself idle,
/// so a second trigger started a second recording — and the second one's failure path ran
/// `studio.cancel()`, deleting the *first* recording's session, and put the desktop icons
/// back while the first was still filming.
@Suite("Recording state")
struct RecordingStateTests {
    /// The question every guard in the coordinator actually means. Asking `== .recording`
    /// is the question almost nobody means, and answering the wrong one is what let two
    /// recordings overlap.
    @Test(
        "A recording that is starting counts as one",
        arguments: [
            (RecordingState.idle, false),
            (.starting, true),
            (.recording, true),
            (.paused, true),
            (.finishing, true)
        ]
    )
    func activeStates(state: RecordingState, isActive: Bool) {
        #expect(state.isActive == isActive)
    }

    @Test("Only idle is inactive")
    func idleIsTheOnlyInactiveState() {
        #expect(!RecordingState.idle.isActive)
        for state in [RecordingState.starting, .recording, .paused, .finishing] {
            #expect(state.isActive, "\(state) should count as a live recording")
        }
    }

    /// The guard, asserted structurally: it has to be claimed before the first `await`, or
    /// the window it exists to close is still open.
    ///
    /// Matched on a prefix of the signature rather than the whole of it, because the whole
    /// of it is not the invariant: adding the `alreadyClaimed` parameter — so a countdown
    /// can hold the claim straight through into the recording without the state visibly
    /// blinking — failed this test for a coordinator whose claim had not moved.
    ///
    /// Over the whole function rather than its first 900 characters, which is what this used
    /// to read. A fixed window makes the test depend on how long the *comments* are: adding
    /// a sentence to the explanation above `state = .starting` pushed `Task {` out of range
    /// and failed the build for a coordinator that was still correct. A test that a comment
    /// can break is a test people learn to ignore.
    @Test("The state is claimed synchronously, before the first await")
    func stateIsClaimedBeforeAwaiting() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Kadr/Recording/RecordingCoordinator.swift"),
            encoding: .utf8
        )
        let found = try #require(
            Self.functionBody(named: "func start(target: RecordingTarget", in: source),
            "RecordingCoordinator.start could not be found; did it get renamed?"
        )
        // Comments stripped before anything is matched. The explanation above the claim
        // contains the words "before the first await", and searching the raw text found
        // *that* — a test that reads its own subject's prose as if it were code.
        let body = Self.strippingComments(from: found)

        let claim = try #require(body.range(of: "state = .starting"))
        let task = try #require(body.range(of: "Task {"))
        #expect(
            claim.lowerBound < task.lowerBound,
            "the state is claimed inside the Task, which leaves the re-entrancy window open"
        )
        // And before *any* suspension, not merely before the Task — the point is that
        // nothing can run between the check and the claim.
        if let suspension = body.range(of: "await ") {
            #expect(
                claim.lowerBound < suspension.lowerBound,
                "something is awaited before the state is claimed"
            )
        }
    }

    /// The same text with `//` comments removed.
    static func strippingComments(from source: some StringProtocol) -> String {
        String(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex ..< comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The text between a declaration's opening brace and its matching close.
    ///
    /// Brace-matched rather than character-counted, so the answer is the function and not
    /// however much of it happens to fit in an arbitrary window.
    static func functionBody(named declaration: String, in source: String) -> Substring? {
        guard let start = source.range(of: declaration),
              let open = source[start.upperBound...].firstIndex(of: "{")
        else {
            return nil
        }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" {
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return source[source.index(after: open) ..< index]
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
