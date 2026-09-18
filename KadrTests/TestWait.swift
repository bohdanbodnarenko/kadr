import Foundation

/// Waits for something the app does a moment from now, without a fixed sleep.
///
/// Three test files had grown their own copy of this. A fixed wait is either flaky on a
/// loaded machine or slow on an idle one; polling is neither, and it returns the instant
/// the condition holds. Gives up after two seconds so a broken expectation fails as a
/// failed `#expect` rather than as a hung suite.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0 ..< 200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
