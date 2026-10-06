import AppKit
import ControlKit
import KeyboardShortcuts
import SettingsKit
import SwiftUI

/// First-run tips: one under the menu-bar icon, one tour the first time the island opens
/// (docs/03 §1.4, §8.2).
///
/// Each shows once. Each closes on its own button, on its ×, and on the thing it is
/// teaching — opening the island ends the menu-bar hint, picking a mode ends the tour —
/// and any of those counts as seen. "Show Tips Again" in Settings, or replaying the
/// welcome, arms them again.
@MainActor
final class CoachMarks {
    private let settings: AppSettings
    private var hint: CoachPopover?
    private var tour: CoachPopover?
    private var tourModel: IslandTourModel?
    private var hintTask: Task<Void, Never>?

    /// Opens the island from the hint's button.
    var openIsland: () -> Void = {}
    /// Opens Settings ▸ Shortcuts from the tour's last step.
    var openShortcutSettings: () -> Void = {}

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// How long after launch (or after the welcome closes) the hint appears: long enough
    /// for the menu bar to settle, short enough to still be about opening Kadr.
    static let hintDelay: Duration = .milliseconds(1200)

    // MARK: - The menu-bar hint

    /// Shows the hint under `button` soon, if it has not been seen.
    ///
    /// - Parameter button: read when the delay is over, not now — the status item can be
    ///   hidden or rebuilt in between.
    func scheduleMenuBarHint(anchor button: @escaping () -> NSStatusBarButton?) {
        guard !settings.hasSeenMenuBarHint, hint == nil else { return }
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hintDelay)
            guard !Task.isCancelled, let self else { return }
            hintTask = nil
            guard let button = button(), button.window?.isVisible == true else { return }
            showMenuBarHint(under: button)
        }
    }

    private func showMenuBarHint(under button: NSStatusBarButton) {
        guard !settings.hasSeenMenuBarHint, hint == nil else { return }
        let popover = CoachPopover()
        popover.onClose = { [weak self] in
            self?.settings.hasSeenMenuBarHint = true
            self?.hint = nil
        }
        hint = popover
        popover.show(
            MenuBarHintView(
                islandShortcut: Self.shortcutText(for: .allInOne),
                open: { [weak self] in
                    self?.dismissMenuBarHint()
                    self?.openIsland()
                },
                dismiss: { [weak self] in self?.dismissMenuBarHint() }
            ),
            relativeTo: button.bounds,
            of: button,
            // Below the icon: the bottom edge is `maxY` in a flipped button.
            edge: button.isFlipped ? .maxY : .minY
        )
        NSAccessibility.post(
            element: button,
            notification: .announcementRequested,
            userInfo: [.announcement: "Tip: click Kadr in the menu bar to capture."]
        )
    }

    /// Ends the hint for good, whichever way the user answered it.
    func dismissMenuBarHint() {
        hintTask?.cancel()
        hintTask = nil
        guard let hint else { return }
        hint.close()
    }

    // MARK: - The island tour

    var isTourNeeded: Bool {
        !settings.hasSeenIslandTour
    }

    /// Starts the tour above the island's glass, the first time the island is up.
    ///
    /// - Parameters:
    ///   - bar: the glass, in `view`'s coordinates.
    ///   - view: the island's hosting view.
    func startIslandTour(pointingAt bar: NSRect, in view: NSView) {
        // The island is usually open because the hint sent the user there.
        dismissMenuBarHint()
        guard isTourNeeded, tour == nil else { return }
        // The pages are read once: the shortcuts they list cannot change while the tour is up.
        let model = IslandTourModel(steps: IslandTourStep.all)
        let popover = CoachPopover()
        popover.onClose = { [weak self] in
            self?.settings.hasSeenIslandTour = true
            self?.tour = nil
            self?.tourModel = nil
        }
        tour = popover
        tourModel = model
        popover.show(
            IslandTourView(
                model: model,
                next: { [weak self] in self?.advanceTour() },
                openSettings: { [weak self] in
                    self?.tour?.close()
                    self?.openShortcutSettings()
                }
            )
            .overlay(alignment: .topTrailing) {
                CoachCloseButton { [weak self] in self?.tour?.close() }
                    .padding(14)
            },
            relativeTo: bar,
            of: view,
            edge: view.isFlipped ? .minY : .maxY
        )
    }

    /// The island went away: a mode was picked, or it was closed. Either way the tour
    /// has done its job.
    func islandDidClose() {
        tour?.close()
    }

    /// Next page, or the end of the tour after the last one.
    func advanceTour() {
        guard let tourModel, tourModel.move(by: 1) else {
            tour?.close()
            return
        }
    }

    /// The page on show, or nil when there is no tour.
    var tourPage: Int? {
        tourModel?.index
    }

    // MARK: - Again

    /// Arms every first-run tip again (Settings ▸ General, and replaying the welcome).
    func resetAll() {
        dismissMenuBarHint()
        tour?.close()
        settings.hasSeenMenuBarHint = false
        settings.hasSeenIslandTour = false
        settings.hasSeenQuickAccessTip = false
    }

    /// The user's shortcut for a command, as the Mac spells it; nil when unassigned.
    static func shortcutText(for command: CaptureCommand) -> String? {
        KeyboardShortcuts.getShortcut(for: command.shortcutName)?.description
    }
}

/// Under the menu-bar icon, once: where Kadr lives and how to open it.
struct MenuBarHintView: View {
    let islandShortcut: String?
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Kadr lives here")
                    .font(.headline)
                Spacer()
                CoachCloseButton(action: dismiss)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let islandShortcut {
                    CoachRow(key: islandShortcut, text: "Open the capture island from any app.")
                }
                CoachRow(symbol: "cursorarrow.click", text: "Or click this icon. Right-click for History and Settings.")
            }
            HStack {
                Spacer()
                Button("Got It", action: dismiss)
                Button("Open It Now", action: open)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(KadrSpace.xl)
        .frame(width: 320)
    }
}
