import AppKit
import os
import Shared

/// One overlay window per display, kept in step with the displays that actually exist.
///
/// Displays come and go while an overlay is up: a monitor is unplugged, a projector
/// wakes, resolution changes, a laptop lid closes. AppKit reports all of it through a
/// single notification, and an overlay that ignores it ends up with a panel sized for a
/// display that is gone — or no panel at all on a display that just appeared.
///
/// This owns that bookkeeping so the selection overlay does not have to.
@MainActor
public final class PerScreenWindowSet<Window: OverlayWindowing> {
    private let screens: any ScreenProviding
    /// Returns `nil` for a display the caller has nothing to show on — a display that
    /// appeared after the content was prepared, say.
    private let makeWindow: (ScreenDescriptor) -> Window?
    private let logger = KadrLog.logger(.overlay)
    private var observation: NotificationObservation?

    /// The live windows, keyed by the display they cover.
    public private(set) var windows: [CGDirectDisplayID: Window] = [:]

    /// Called after a display change has been reconciled, so the owner can refresh
    /// anything that depends on the display list.
    public var onScreensChanged: (([ScreenDescriptor]) -> Void)?

    public init(
        screens: any ScreenProviding = SystemScreens(),
        makeWindow: @escaping (ScreenDescriptor) -> Window?
    ) {
        self.screens = screens
        self.makeWindow = makeWindow
    }

    public var isPresented: Bool {
        !windows.isEmpty
    }

    public var descriptors: [ScreenDescriptor] {
        presentedScreens
    }

    private var presentedScreens: [ScreenDescriptor] = []

    /// Puts one window on every display and starts watching for display changes.
    @discardableResult
    public func present() -> [ScreenDescriptor] {
        let descriptors = screens.currentScreens()
        presentedScreens = descriptors
        for descriptor in descriptors {
            guard let window = makeWindow(descriptor) else { continue }
            window.present(on: descriptor)
            windows[descriptor.displayID] = window
        }
        startObservingScreenChanges()
        logger.debug("Presented overlay on \(descriptors.count, privacy: .public) display(s)")
        return descriptors
    }

    /// Tears every window down and stops observing.
    ///
    /// Everything is released here, because the overlay's whole memory cost — a
    /// full-screen frozen bitmap per display — must go back to the OS the moment the
    /// user is done (PRD §8).
    public func dismiss() {
        for window in windows.values {
            window.dismiss()
        }
        windows.removeAll()
        presentedScreens = []
        stopObservingScreenChanges()
    }

    public func window(for displayID: CGDirectDisplayID) -> Window? {
        windows[displayID]
    }

    // MARK: - Display changes

    private func startObservingScreenChanges() {
        guard observation == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileScreens()
            }
        }
        observation = NotificationObservation(token: token)
    }

    private func stopObservingScreenChanges() {
        // Releasing the observation removes the observer.
        observation = nil
    }

    /// Adds windows for new displays, drops them for departed ones, and repositions the
    /// rest — a resolution change keeps the same display ID but moves the frame.
    public func reconcileScreens() {
        guard isPresented else { return }
        let current = screens.currentScreens()
        let currentIDs = Set(current.map(\.displayID))

        for (displayID, window) in windows where !currentIDs.contains(displayID) {
            window.dismiss()
            windows.removeValue(forKey: displayID)
            logger.debug("Display \(displayID, privacy: .public) went away; overlay removed")
        }

        for descriptor in current {
            if let existing = windows[descriptor.displayID] {
                existing.present(on: descriptor)
            } else if let window = makeWindow(descriptor) {
                window.present(on: descriptor)
                windows[descriptor.displayID] = window
                logger.debug("Display \(descriptor.displayID, privacy: .public) appeared; overlay added")
            }
        }

        presentedScreens = current
        onScreensChanged?(current)
    }
}

/// Owns a `NotificationCenter` block-observer token and removes it on deallocation.
///
/// This exists so `PerScreenWindowSet` needs no `deinit` of its own. A main-actor class
/// cannot touch its state from a `nonisolated deinit`, and the `isolated deinit` that
/// would allow it crashes the Swift 6.3.3 optimizer while inlining the destructor
/// (`EarlyPerfInliner` on `PerScreenWindowSetCfD`, release builds only). Wrapping the
/// token in a class whose own deinit is plain and non-isolated sidesteps the whole
/// question and is clearer besides: the observation's lifetime is now a value you can
/// hold rather than a rule you have to remember.
private final class NotificationObservation: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        // Safe from any thread: NotificationCenter's own removal is thread-safe, and the
        // token is opaque and never touched for anything else.
        NotificationCenter.default.removeObserver(token)
    }
}
