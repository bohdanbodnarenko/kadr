import AppKit
import CaptureCore
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// The All-in-One capture strip (docs/03 §1.4, CleanShot §5).
///
/// One shortcut, one compact HUD, then a mode. Hotkeys stay the fast path; this is the
/// discoverable one — and what a click on the menu-bar icon opens (docs/03 §8.1).
///
/// Its own panel, not the recording bar: mixing the two meant starting a recording from
/// here tore down a stills HUD, and the other way around left the recorder looking like
/// a screenshot tool. Destroyed when idle (PRD §8).
@MainActor
final class AllInOneHUD {
    private var panel: NonActivatingPanel?
    private var hosting: NSHostingView<AllInOneView>?
    private let model: AllInOneModel

    init(
        settings: AppSettings,
        perform: @escaping (AllInOneMode) -> Void,
        pickDisplay: @escaping (CGDirectDisplayID) -> Void = { _ in },
        performTool: @escaping (AllInOneTool) -> Void = { _ in },
        desktopIconsHidden: @escaping () -> Bool = { false }
    ) {
        model = AllInOneModel(settings: settings, perform: perform, pickDisplay: pickDisplay)
        model.onTool = performTool
        model.desktopIconsHidden = desktopIconsHidden
    }

    var isShowing: Bool {
        panel != nil
    }

    /// Fired when the HUD appears or goes away, so the menu bar can show the armed state.
    var onShowingChanged: (() -> Void)?
    /// A new island is on screen: its hosting view and the glass inside it, for the
    /// first-open tour to point at.
    var onPresented: ((NSView, NSRect) -> Void)?
    /// The island is going away, however it was closed.
    var onClosed: (() -> Void)?

    func toggle() {
        if isShowing {
            dismiss()
        } else {
            present()
        }
    }

    var frontmostBeforePresent: AppIdentity?

    /// - Parameter source: the recorder's bar in screen space, when the island is coming
    ///   back from it. The island fades in on that spot rather than jumping to its own.
    func present(morphingFrom source: NSRect? = nil) {
        model.onCancel = { [weak self] in self?.dismiss() }
        model.onPicked = { [weak self] in self?.dismiss() }
        model.onHandOff = { [weak self] in self?.handOff() }

        if frontmostBeforePresent == nil {
            frontmostBeforePresent = AreaCaptureCoordinator.currentFrontmostApp()
        }

        if let panel {
            panel.alphaValue = 1
            takeKeyboard(panel)
            return
        }

        let hosting = NSHostingView(rootView: AllInOneView(model: model))
        hosting.sizingOptions = .intrinsicContentSize
        let size = RecordingBarMetrics.resolvedIslandSize(fitting: hosting.fittingSize)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NonActivatingPanel(contentRect: hosting.frame, level: .floating)
        panel.contentView = hosting
        let fadesIn = source != nil && !AccessibilityChrome.reduceMotion
        panel.setFrame(source.map { Self.frame(for: size, onBar: $0) } ?? Self.centeredFrame(for: size), display: false)
        if fadesIn {
            panel.alphaValue = 0
        }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        CaptureExclusionRegistry.shared.register(panel)
        takeKeyboard(panel)
        if fadesIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        self.panel = panel
        self.hosting = hosting
        onShowingChanged?()
        if let onPresented {
            // A turn later, once the panel is on screen and laid out: a popover shown
            // against a view that is not yet in a visible window does not appear.
            let bar = Self.barFrame(inHostingBounds: hosting.bounds, flipped: hosting.isFlipped)
            Task { @MainActor [weak self, weak hosting] in
                guard let hosting, self?.hosting === hosting else { return }
                onPresented(hosting, bar)
            }
        }
    }

    /// Brings the island forward and gives it the keyboard.
    ///
    /// Activate first, then take key: Kadr is an accessory app, and a borderless
    /// non-activating panel asked to become key while the app is still inactive can be
    /// refused — after which `NSApp.activate` hands key status back to whatever window was
    /// last key, not to the island. The explicit `makeFirstResponder` is the other half:
    /// the island is re-shown without SwiftUI's `onAppear` running again, so the hosting
    /// view has to be put back in the responder chain by hand or the letters stay dead.
    private func takeKeyboard(_ panel: NSPanel) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let content = panel.contentView {
            panel.makeFirstResponder(content)
        }
    }

    /// The glass inside the hosting view, in its own coordinates.
    static func barFrame(inHostingBounds bounds: NSRect, flipped: Bool) -> NSRect {
        let slack = RecordingBarMetrics.shadowSlack
        let reserve = RecordingBarMetrics.tooltipReserve
        return NSRect(
            x: bounds.minX + slack,
            y: flipped ? bounds.minY + slack + reserve : bounds.minY + slack,
            width: max(bounds.width - slack * 2, 0),
            height: max(bounds.height - slack * 2 - reserve, 0)
        )
    }

    /// A panel whose glass sits with its bottom edge centred on `bar`'s.
    static func frame(for size: CGSize, onBar bar: NSRect) -> NSRect {
        NSRect(
            x: bar.midX - size.width / 2,
            y: bar.minY - RecordingBarMetrics.shadowSlack,
            width: size.width,
            height: size.height
        )
    }

    func dismiss() {
        guard let panel else { return }
        onClosed?()
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        hosting = nil
        onShowingChanged?()
    }

    /// The glass capsule in screen space: the panel less the slack `RecordingIslandSurface`
    /// pads around it for the tooltip and the shadow.
    static func barFrame(inPanel frame: NSRect) -> NSRect {
        let slack = RecordingBarMetrics.shadowSlack
        return NSRect(
            x: frame.minX + slack,
            y: frame.minY + slack,
            width: max(frame.width - slack * 2, 0),
            height: max(frame.height - slack * 2 - RecordingBarMetrics.tooltipReserve, 0)
        )
    }

    /// Where the island's glass was when Record was picked, for the recording bar to open
    /// on. Read once.
    func takeHandOffFrame() -> NSRect? {
        defer { handOffFrame = nil }
        return handOffFrame
    }

    private var handOffFrame: NSRect?
    private static let handOffFade: TimeInterval = 0.18

    /// Leaves for the recorder: remembers where the glass was and fades rather than
    /// vanishing, so the recording bar can grow out of the same spot.
    ///
    /// Only for Record. Every other mode freezes the screen next, and a panel still fading
    /// while the freeze is taken would be in the picture.
    private func handOff() {
        guard let panel else { return }
        onClosed?()
        handOffFrame = Self.barFrame(inPanel: panel.frame)
        guard !AccessibilityChrome.reduceMotion else {
            dismiss()
            return
        }
        RecordingBarHoverView.endActiveHover()
        CaptureExclusionRegistry.shared.unregister(panel)
        self.panel = nil
        hosting = nil
        onShowingChanged?()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.handOffFade
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }
        // One-shot, on the main actor: the animation's own completion handler is
        // `@Sendable` and may not touch the window.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.handOffFade + 0.05))
            panel.orderOut(nil)
            panel.contentView = nil
        }
    }

    /// Bottom-centre of the pointer's screen, clear of the menu bar and most window chrome.
    private static func centeredFrame(for size: CGSize) -> NSRect {
        let visible = (ActiveScreen.resolve()?.visibleFrame)
            ?? (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? .zero
        let margin: CGFloat = 22
        let x = visible.midX - size.width / 2
        let y = visible.minY + margin
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

@MainActor
@Observable
final class AllInOneModel {
    let settings: AppSettings
    @ObservationIgnored private let perform: (AllInOneMode) -> Void
    @ObservationIgnored var onPicked: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    /// Record is not a capture: the island hands over to the recorder instead of closing.
    @ObservationIgnored var onHandOff: () -> Void = {}
    @ObservationIgnored var onPickDisplay: (CGDirectDisplayID) -> Void = { _ in }
    @ObservationIgnored var onTool: (AllInOneTool) -> Void = { _ in }
    @ObservationIgnored var desktopIconsHidden: () -> Bool = { false }

    init(
        settings: AppSettings,
        perform: @escaping (AllInOneMode) -> Void,
        pickDisplay: @escaping (CGDirectDisplayID) -> Void = { _ in }
    ) {
        self.settings = settings
        self.perform = perform
        onPickDisplay = pickDisplay
    }

    var lastMode: AllInOneMode {
        AllInOneMode(rawValue: settings.lastAllInOneMode) ?? .area
    }

    func pick(_ mode: AllInOneMode) {
        settings.lastAllInOneMode = mode.rawValue
        if mode == .record {
            onHandOff()
        } else {
            onPicked()
        }
        perform(mode)
    }

    /// Closes the island first, so a tool that captures does not capture the island.
    func use(_ tool: AllInOneTool) {
        onPicked()
        onTool(tool)
    }

    func pickLast() {
        pick(lastMode)
    }

    func cancel() {
        onCancel()
    }
}
