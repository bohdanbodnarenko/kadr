import AppKit
import os
import OverlayKit
import Shared

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

    init(frozen: FrozenDisplay, screen: ScreenDescriptor) {
        let frame = screen.frame.cgRect
        overlayView = SelectionOverlayView(
            frozenImage: frozen.image,
            bounds: CGRect(origin: .zero, size: frame.size),
            scale: frozen.geometry.scale
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
    private var completion: ((SelectionResult?) -> Void)?
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
    public func present(
        freezes: [FrozenDisplay],
        signpostState: OSSignpostIntervalState? = nil,
        completion: @escaping (SelectionResult?) -> Void
    ) {
        // A second hotkey while the overlay is up re-freezes rather than stacking
        // overlays (docs/03 §1.1 edge cases).
        if isPresented {
            dismiss(result: nil)
        }

        self.completion = completion
        self.freezes = Dictionary(uniqueKeysWithValues: freezes.map { ($0.geometry.displayID, $0) })
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
        let panel = SelectionPanel(frozen: frozen, screen: descriptor)

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
            dismiss(result: SelectionResult(
                rect: global,
                display: frozen.geometry,
                localRect: localRect
            ))
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

    private func dismiss(result: SelectionResult?) {
        guard let windowSet else { return }
        windowSet.dismiss()
        self.windowSet = nil
        freezes.removeAll()

        // Hand focus back to whatever the user was in, so the overlay is invisible in
        // the app-switching sense as well as the visual one.
        previouslyActiveApp?.activate()
        previouslyActiveApp = nil

        let completion = completion
        self.completion = nil
        completion?(result)
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
