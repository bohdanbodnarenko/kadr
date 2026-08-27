import AppKit
import os
import OverlayKit
import Shared

/// Which interaction the overlay opens in.
public enum SelectionMode: Sendable {
    case area
    case window
}

/// One display's frozen contents, handed to the overlay.
///
/// SelectionUI deliberately does not depend on CaptureCore: the overlay's job is to turn
/// a frozen bitmap into a chosen rect, and keeping it ignorant of ScreenCaptureKit means
/// it can be exercised with any image.
public struct FrozenDisplay: Sendable {
    public let geometry: DisplayGeometry
    public let image: CGImage

    public init(geometry: DisplayGeometry, image: CGImage) {
        self.geometry = geometry
        self.image = image
    }
}

/// A window the user picked in window mode (docs/03 §1.2).
public struct WindowSelection: Sendable {
    public let window: PickableWindow
    public let display: DisplayGeometry
    /// ⌥ was held at click, so this capture inverts the saved shadow setting.
    public let togglesShadow: Bool

    public init(window: PickableWindow, display: DisplayGeometry, togglesShadow: Bool) {
        self.window = window
        self.display = display
        self.togglesShadow = togglesShadow
    }
}

/// What the overlay resolved to.
public enum SelectionOutcome: Sendable {
    case region(SelectionResult)
    case window(WindowSelection)
}

/// What the user chose.
public struct SelectionResult: Sendable {
    /// The chosen rect in global display space, ready for `captureRegion`.
    public let rect: DisplayRect
    public let display: DisplayGeometry
    /// The rect in display-local points, for cropping straight out of the frozen image.
    public let localRect: CGRect

    public init(rect: DisplayRect, display: DisplayGeometry, localRect: CGRect) {
        self.rect = rect
        self.display = display
        self.localRect = localRect
    }
}

/// A borderless overlay panel carrying one display's selection surface.
@MainActor
final class SelectionPanel: NonActivatingPanel, OverlayWindowing {
    private let overlayView: SelectionOverlayView

    init(frozen: FrozenDisplay, screen: ScreenDescriptor, mode: SelectionOverlayView.Mode) {
        let frame = screen.frame.cgRect
        overlayView = SelectionOverlayView(
            frozenImage: frozen.image,
            bounds: CGRect(origin: .zero, size: frame.size),
            scale: frozen.geometry.scale,
            mode: mode
        )
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureAsOverlay()
        contentView = overlayView
    }

    var view: SelectionOverlayView {
        overlayView
    }

    func present(on screen: ScreenDescriptor) {
        setFrame(screen.frame.cgRect, display: true)
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(overlayView)
    }

    func dismiss() {
        // Drop the frozen bitmap with the view — it is the overlay's whole memory cost.
        contentView = nil
        orderOut(nil)
        close()
    }
}

/// Runs the area-selection interaction across every display (docs/03 §1.1).
///
/// The overlay exists only between the hotkey and the user's answer. Everything it owns —
/// one full-screen bitmap per display, the panels, the layer trees — is created on
/// `present` and released on `dismiss`, because a 5K freeze is roughly 59 MB and the
/// agent's whole idle budget is half that (PRD §8).
@MainActor
public final class SelectionOverlayController {
    private let screens: any ScreenProviding
    private let logger = KadrLog.logger(.overlay)
    private let signposter = KadrLog.signposter(.overlay)

    private var windowSet: PerScreenWindowSet<SelectionPanel>?
    private var freezes: [CGDirectDisplayID: FrozenDisplay] = [:]
    private var completion: ((SelectionOutcome?) -> Void)?
    private var mode: SelectionOverlayView.Mode = .area
    /// Windows offered for picking, keyed by the display they are shown on.
    private var pickableWindows: [CGDirectDisplayID: [PickableWindow]] = [:]
    private var previouslyActiveApp: NSRunningApplication?

    public init(screens: any ScreenProviding = SystemScreens()) {
        self.screens = screens
    }

    public var isPresented: Bool {
        windowSet?.isPresented ?? false
    }

    /// Shows the frozen screen and resolves with the user's selection, or `nil` on Esc.
    ///
    /// - Parameter signpostState: the interval opened at hotkey time, closed here once
    ///   the overlay is actually on screen — that is the <100 ms budget in PRD §8.
    /// - Parameters:
    ///   - mode: whether to start in region or window-pick mode (docs/03 §1.1, §1.2).
    ///   - windows: the windows available to pick, in front-to-back order and in global
    ///     display space. Ignored in region mode.
    public func present(
        freezes: [FrozenDisplay],
        mode: SelectionMode = .area,
        windows: [PickableWindowDescriptor] = [],
        signpostState: OSSignpostIntervalState? = nil,
        completion: @escaping (SelectionOutcome?) -> Void
    ) {
        // A second hotkey while the overlay is up re-freezes rather than stacking
        // overlays (docs/03 §1.1 edge cases).
        if isPresented {
            dismiss(result: nil)
        }

        self.completion = completion
        self.mode = mode == .window ? .window : .area
        self.freezes = Dictionary(uniqueKeysWithValues: freezes.map { ($0.geometry.displayID, $0) })
        pickableWindows = Self.mapWindows(windows, onto: freezes.map(\.geometry))
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication

        let set = PerScreenWindowSet<SelectionPanel>(screens: screens) { [weak self] descriptor in
            self?.makePanel(for: descriptor)
        }
        set.onScreensChanged = { [weak self] _ in
            // A display appearing mid-selection gets a panel with no frozen image; the
            // honest thing is to abandon rather than let the user select from a blank.
            self?.logger.info("Display configuration changed during selection; dismissing")
            self?.dismiss(result: nil)
        }
        windowSet = set
        set.present()

        if let signpostState {
            signposter.endInterval("hotkeyToOverlay", signpostState)
        }
        logger.info("Selection overlay presented on \(set.windows.count, privacy: .public) display(s)")
    }

    /// Tears the overlay down without a selection.
    public func cancel() {
        dismiss(result: nil)
    }

    private func makePanel(for descriptor: ScreenDescriptor) -> SelectionPanel? {
        guard let frozen = freezes[descriptor.displayID] else { return nil }
        let panel = SelectionPanel(frozen: frozen, screen: descriptor, mode: mode)
        panel.view.setPickableWindows(pickableWindows[descriptor.displayID] ?? [])

        panel.view.onModeChanged = { [weak self] newMode in
            guard let self else { return }
            mode = newMode
            for panel in windowSet?.windows.values ?? [:].values {
                panel.view.setMode(newMode)
            }
        }
        panel.view.onCommitWindow = { [weak self] window, togglesShadow in
            self?.dismiss(result: .window(WindowSelection(
                window: window,
                display: frozen.geometry,
                togglesShadow: togglesShadow
            )))
        }

        panel.view.onCancel = { [weak self] in
            self?.dismiss(result: nil)
        }
        panel.view.onBecameActive = { [weak self] in
            self?.makeActive(displayID: descriptor.displayID)
        }
        panel.view.onCommit = { [weak self] localRect in
            guard let self else { return }
            let global = DisplayRect(
                x: frozen.geometry.frame.minX + localRect.minX,
                y: frozen.geometry.frame.minY + localRect.minY,
                width: localRect.width,
                height: localRect.height
            )
            dismiss(result: .region(SelectionResult(
                rect: global,
                display: frozen.geometry,
                localRect: localRect
            )))
        }
        return panel
    }

    /// Only the display under the pointer draws a loupe and crosshair.
    private func makeActive(displayID: CGDirectDisplayID) {
        guard let windowSet else { return }
        for (id, panel) in windowSet.windows {
            panel.view.setActive(id == displayID)
        }
    }

    private func dismiss(result: SelectionOutcome?) {
        guard let windowSet else { return }
        windowSet.dismiss()
        self.windowSet = nil
        freezes.removeAll()
        pickableWindows.removeAll()

        // Hand focus back to whatever the user was in, so the overlay is invisible in
        // the app-switching sense as well as the visual one.
        previouslyActiveApp?.activate()
        previouslyActiveApp = nil

        let completion = completion
        self.completion = nil
        completion?(result)
    }

    /// Maps global window frames onto every display that shows them, keeping the
    /// front-to-back order each display sees.
    /// Public so the mapping can be tested directly; it is the piece with real logic.
    public static func mapWindows(
        _ descriptors: [PickableWindowDescriptor],
        onto displays: [DisplayGeometry]
    ) -> [CGDirectDisplayID: [PickableWindow]] {
        var result: [CGDirectDisplayID: [PickableWindow]] = [:]
        for display in displays {
            result[display.displayID] = descriptors.compactMap { $0.mapped(onto: display) }
        }
        return result
    }
}

public extension FrozenDisplay {
    /// Crops the selection straight out of the frozen bitmap.
    ///
    /// This is what makes area capture WYSIWYG (docs/03 §1.1). Re-capturing the region
    /// after the user releases the mouse would photograph whatever the screen shows
    /// *then* — a video that has advanced, a menu that has closed, a notification that
    /// arrived — instead of the frozen frame they actually selected on.
    ///
    /// - Parameter localRect: the selection in display-local points.
    func croppedImage(localRect: CGRect) -> CGImage? {
        guard !localRect.isEmpty else { return nil }
        let pixels = geometry.pixels(for: DisplayRect(cgRect: localRect))
        guard !pixels.isEmpty else { return nil }

        let clamped = pixels.cgRect.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard !clamped.isEmpty else { return nil }
        return image.cropping(to: clamped)
    }
}
