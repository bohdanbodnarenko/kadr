import AppKit
import Foundation

/// Which parts of an always-on-top panel actually take clicks (docs/09 U2.1).
///
/// The problem with a floating card: it is a rectangle of window, and a window takes every
/// click inside it. Most of that rectangle is padding, shadow and rounded corner — space
/// where the user can see the app underneath and reasonably expects to be able to click it.
/// Swallowing those clicks is the single most irritating thing an overlay can do.
///
/// The fix is to publish the *interactive* rects — the buttons, the thumbnail, the drag
/// handle — and let everything else pass through. There is no per-region pass-through in
/// AppKit, so what actually happens is that the panel's `ignoresMouseEvents` is flipped as
/// the pointer moves: inside a control it takes events, everywhere else it does not exist.
///
/// This type is the decision; `InteractiveRegionTracker` is the plumbing that applies it.
public struct InteractiveRegions: Equatable, Sendable {
    /// Interactive areas, in screen coordinates.
    public var rects: [CGRect]

    public init(rects: [CGRect] = []) {
        self.rects = rects
    }

    public static let none = InteractiveRegions()

    /// Whether a screen point lands on something clickable.
    public func containsInteractiveContent(at point: CGPoint) -> Bool {
        rects.contains { $0.contains(point) }
    }

    /// Whether the panel should let this point through to whatever is underneath.
    public func shouldPassThrough(at point: CGPoint) -> Bool {
        !containsInteractiveContent(at: point)
    }

    /// The regions grown by `slop` on every side.
    ///
    /// A hit target the exact size of the drawn control is a target the user misses: the
    /// pointer arrives a pixel early, the panel disappears from under it, and the click
    /// lands in the app behind. The slop is what makes the boundary forgiving.
    public func expanded(by slop: CGFloat) -> InteractiveRegions {
        InteractiveRegions(rects: rects.map { $0.insetBy(dx: -slop, dy: -slop) })
    }
}

/// A window that says which parts of itself take clicks.
@MainActor
public protocol InteractivelyMasked: AnyObject {
    /// Interactive areas in screen coordinates. Empty means the whole window is inert.
    var interactiveRegions: InteractiveRegions { get }
    /// Applied by the tracker as the pointer moves.
    var passesMouseThrough: Bool { get set }
}

/// Flips pass-through on registered panels as the pointer moves (docs/09 U2.1).
///
/// A mouse-moved monitor is a real cost, so it exists only while there is a panel to
/// track — registering the first one starts it and unregistering the last one stops it. An
/// agent with no cards on screen installs nothing, which is the state it is in almost
/// always (CLAUDE.md rule 2).
@MainActor
public final class InteractiveRegionTracker {
    public static let shared = InteractiveRegionTracker()

    /// How much bigger than the drawn control a hit target is.
    public static let hitSlop: CGFloat = 2

    private final class Entry {
        weak var panel: (any InteractivelyMasked)?

        init(panel: any InteractivelyMasked) {
            self.panel = panel
        }
    }

    private var entries: [Entry] = []
    private var monitor: Any?

    public init() {}

    // No `deinit` cleanup. The monitor is removed when the last panel unregisters, which
    // is deterministic; reaching for it from a `deinit` would mean touching main-actor
    // state from wherever the last reference happened to be released (docs/07 LOW). The
    // tracker is a process-lifetime singleton in practice, so there is nothing to clean up
    // after anyway.

    public func register(_ panel: any InteractivelyMasked) {
        sweep()
        guard !entries.contains(where: { $0.panel === panel }) else { return }
        entries.append(Entry(panel: panel))
        update(at: NSEvent.mouseLocation)
        startTrackingIfNeeded()
    }

    public func unregister(_ panel: any InteractivelyMasked) {
        entries.removeAll { $0.panel === panel || $0.panel == nil }
        // A panel on its way out takes events again, so its own teardown is not fighting
        // a pass-through it can no longer update.
        panel.passesMouseThrough = false
        stopTrackingIfIdle()
    }

    /// Applies the current pointer position to every registered panel.
    ///
    /// Public so a panel can re-evaluate after its own layout changes — the pointer has
    /// not moved, but what is under it has.
    public func update(at screenPoint: CGPoint) {
        sweep()
        for entry in entries {
            guard let panel = entry.panel else { continue }
            let regions = panel.interactiveRegions.expanded(by: Self.hitSlop)
            panel.passesMouseThrough = regions.shouldPassThrough(at: screenPoint)
        }
    }

    private func startTrackingIfNeeded() {
        guard monitor == nil, !entries.isEmpty else { return }
        // A global monitor observes without intercepting and needs no permission, which is
        // exactly right for "where is the pointer".
        let matching: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: matching) { [weak self] _ in
            self?.update(at: NSEvent.mouseLocation)
        }
    }

    private func stopTrackingIfIdle() {
        sweep()
        guard entries.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func sweep() {
        entries.removeAll { $0.panel == nil }
    }
}
