import Foundation

/// How many recordings a crash left mid-edit, kept so the status menu never has to ask the
/// disk while it is opening (docs/09 U3.1, PRD §8).
///
/// Counting means listing every session package, sorting them by a date read from the file
/// system, and checking three files in each — all of which ran on the main thread between
/// the click on the menu-bar icon and the menu appearing. The count changes only when a
/// recording or an editing session ends, so it is taken off the main thread at launch,
/// after each recording, and whenever the menu opens (for an editor that quit meanwhile),
/// and the menu shows the last answer until a fresh one arrives.
///
/// No timer and no file-system watcher: a recount happens only because something else
/// already woke the agent.
@MainActor
final class UnfinishedRecordingsCounter {
    /// The last count taken; zero until the first recount finishes.
    private(set) var latest = 0
    private var recount: Task<Int, Never>?
    private let counter: @Sendable () -> Int

    /// - Parameter counter: does the counting. Runs on a detached task, never on the main
    ///   actor; a seam so tests need no session folders.
    init(counter: @escaping @Sendable () -> Int = { StudioSessionRecorder.unfinishedCount() }) {
        self.counter = counter
    }

    /// Recounts off the main thread, joining a recount already in flight, and reports the
    /// new count on the main actor.
    func refresh(completion: ((Int) -> Void)? = nil) {
        let task = recount ?? startRecount()
        Task { [weak self] in
            let value = await task.value
            if let self, recount == task {
                recount = nil
                latest = value
            }
            completion?(value)
        }
    }

    private func startRecount() -> Task<Int, Never> {
        let counter = counter
        let task = Task.detached(priority: .utility) { counter() }
        recount = task
        return task
    }
}
