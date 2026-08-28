import Foundation
import Observation

/// Cheap while you drag, exact when you stop (docs/09 U1.3).
///
/// Some editor effects cannot be rendered inside a frame. A masked variable blur over a 5K
/// capture is tens of milliseconds; a perspective projection is a full CoreImage pass. Run
/// either on every slider tick and the control stops tracking the pointer, which reads as
/// the app being broken rather than as the effect being expensive.
///
/// The pattern that fixes it is the same one every mature editor uses: show something cheap
/// and approximately right while the value is moving, and render the real thing once it
/// stops. This type is only the *timing* half of that — it says when a value is moving and
/// when it has settled. What "cheap" means is the caller's business, because it differs per
/// effect.
///
/// Deliberately not a `Timer`: the agent's zero-timer rule is about the idle process, but
/// the principle holds here too. A cancellable `Task` that exists only between a change and
/// its settle costs nothing when nobody is dragging anything.
@MainActor
@Observable
public final class SettlePreview {
    /// True from the first change until the value has been still for `settleDelay`.
    ///
    /// Observed, so a view can render its cheap approximation while it is true and the real
    /// thing when it flips back.
    public private(set) var isSettling = false

    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private let onSettle: () -> Void

    /// - Parameters:
    ///   - settleMilliseconds: how still the value has to be before the real render runs.
    ///     Long enough that a continuous drag never triggers one, short enough that
    ///     releasing the mouse feels immediate.
    ///   - onSettle: run on the main actor once the value stops changing.
    public init(settleMilliseconds: Int = 140, onSettle: @escaping () -> Void) {
        settleDelay = .milliseconds(settleMilliseconds)
        self.onSettle = onSettle
    }

    deinit {
        // No `MainActor.assumeIsolated` here: a deinit runs wherever the last reference is
        // released, and assuming an isolation that does not hold crashes the process
        // (docs/07 LOW). Cancelling a `Task` is safe from anywhere.
        settleTask?.cancel()
    }

    /// The value changed. Restarts the settle countdown.
    public func touch() {
        isSettling = true
        settleTask?.cancel()
        settleTask = Task { [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    /// Runs the real render now, without waiting — for a caller that knows the drag is
    /// over, such as a mouse-up.
    public func settleNow() {
        settleTask?.cancel()
        settleTask = nil
        settle()
    }

    /// Abandons a pending render. The cheap preview stays on screen.
    public func cancel() {
        settleTask?.cancel()
        settleTask = nil
        isSettling = false
    }

    private func settle() {
        settleTask = nil
        isSettling = false
        onSettle()
    }
}
