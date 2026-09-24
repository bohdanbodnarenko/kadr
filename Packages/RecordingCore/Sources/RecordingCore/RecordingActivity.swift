import Foundation

/// Holds the Mac awake while a recording is running (docs/16 REC-6).
///
/// Only while a take is in flight — never at idle — so the agent still has no timers
/// and no extra RAM when nothing is recording (CLAUDE.md rule 2).
public protocol RecordingActivitySession: Sendable {
    func end()
}

public protocol RecordingActivityAsserting: Sendable {
    func begin() -> any RecordingActivitySession
}

/// `ProcessInfo.beginActivity` with idle system *and display* sleep disabled.
///
/// Display sleep too: a hands-off narrated take has no input for minutes, and a display
/// that dims or sleeps mid-take is recorded dimming (docs/17 T-REC-10).
public struct ProcessInfoRecordingActivity: RecordingActivityAsserting, Sendable {
    public init() {}

    public func begin() -> any RecordingActivitySession {
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Kadr is recording the screen"
        )
        return ProcessInfoActivitySession(token: token)
    }
}

final class ProcessInfoActivitySession: RecordingActivitySession, @unchecked Sendable {
    private let token: NSObjectProtocol
    private var ended = false

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func end() {
        guard !ended else { return }
        ended = true
        ProcessInfo.processInfo.endActivity(token)
    }
}

/// Counts begin/end pairs so the engine's assertion can be tested without touching sleep.
public final class CountingRecordingActivity: RecordingActivityAsserting, RecordingActivitySession,
    @unchecked Sendable {
    public private(set) var begins = 0
    public private(set) var ends = 0

    public init() {}

    public func begin() -> any RecordingActivitySession {
        begins += 1
        return self
    }

    public func end() {
        ends += 1
    }
}
