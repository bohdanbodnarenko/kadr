import AppKit
import os
import OverlayKit
import Shared

/// Which interaction the overlay opens in.
public enum SelectionMode: Sendable {
    case area
    case window
}

/// What the selection is for, which changes how the overlay looks (docs/03 §1.7).
///
/// Capture Text uses the same selection interaction, so the only honest way to tell the
/// user which one they triggered is to make the overlay look different.
public enum SelectionPurpose: Sendable {
    case capture
    case recognizeText
    /// Choosing the window onto a long page, which Kadr then scrolls through (docs/03 §1.6).
    case scrollingCapture
    /// Freeze to inspect moving UI, then capture from the frozen frames (docs/03 §7).
    case inspect

    /// A badge shown by the crosshair.
    public var badge: String? {
        switch self {
        case .capture: nil
        case .recognizeText: "TEXT"
        case .scrollingCapture: "SCROLL"
        case .inspect: "FREEZE"
        }
    }
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
    /// `F` on the area overlay, this display at full size (docs/03 §1.3).
    case fullscreen(CGDirectDisplayID)
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
    private var purpose: SelectionPurpose = .capture
    /// Windows offered for picking, keyed by the display they are shown on.
    private var pickableWindows: [CGDirectDisplayID: [PickableWindow]] = [:]
    /// Where activation goes back to on dismiss; never Kadr itself (T-CAP-3).
    private var previouslyActiveApp: NSRunningApplication?
    private var isPrecisionMode = false
    /// Fired when the user toggles precision guides with `C` (docs/03 §7).
    public var onPrecisionModeChanged: ((Bool) -> Void)?

    /// A colour was picked with the eyedropper (docs/03 §3 P3, docs/06 M22).
    ///
    /// Separate from the selection outcome because it is a different kind of answer: the
    /// user wanted a value, not a rectangle, and the overlay dismisses either way.
    public var onColorPicked: ((ColorPick) -> Void)?
    private var isEyedropperMode = false

    /// Whether the selection sticks to the edges in the frozen screen (docs/03 §8.3,
    /// docs/06 M21). The app sets this from Settings → Capture.
    public var snapsToEdges = true
    /// Width:height lock for area drags, from Settings / All-in-One (docs/03 §1.1, CleanShot §5).
    ///
    /// Nil is freeform. ⇧ still forces a square on top of this.
    public var lockedAspect: CGSize? {
        didSet { applyLockedAspect() }
    }

    /// Teaching copy while the overlay is idle (docs/03 §1.1).
    public var showsCaptureHints = true
    /// When true, mouse-up leaves handles until Enter commits (docs/03 §1.1).
    public var confirmsSelection = false

    /// The previous area capture, drawn as a dashed ghost on that display.
    public var lastRegion: (rect: DisplayRect, displayID: CGDirectDisplayID)?
    /// How close an edge has to be before the selection takes it, in points.
    public var snapTolerance: CGFloat = 6
    /// The detection pass, so a second hotkey abandons the first one's work.
    private var snapTask: Task<Void, Never>?
    private var snapping: [CGDirectDisplayID: SelectionSnapping] = [:]

    public init(screens: any ScreenProviding = SystemScreens()) {
        self.screens = screens
    }

    public var isPresented: Bool {
        windowSet?.isPresented ?? false
    }

    /// Why the overlay is up. Freeze inspect stays `.inspect` until it is dismissed.
    public var currentPurpose: SelectionPurpose {
        purpose
    }

    /// Shows the frozen screen and resolves with the user's selection, or `nil` on Esc.
    ///
    /// - Parameter signpostState: the interval opened at hotkey time, closed here once
    ///   the overlay is actually on screen — that is the <100 ms budget in PRD §8.
    /// - Parameters:
    ///   - mode: whether to start in region or window-pick mode (docs/03 §1.1, §1.2).
    ///   - windows: the windows available to pick, in front-to-back order and in global
    ///     display space. Ignored in region mode.
    ///   - returningFocusTo: the app to hand activation back to on dismiss, if Kadr holds
    ///     it then. The caller knows better than the overlay: by the time the overlay is up,
    ///     the island may have made Kadr frontmost.
    public func present(
        freezes: [FrozenDisplay],
        mode: SelectionMode = .area,
        purpose: SelectionPurpose = .capture,
        windows: [PickableWindowDescriptor] = [],
        precisionMode: Bool = false,
        eyedropper: Bool = false,
        returningFocusTo: NSRunningApplication? = ActivationJuggler.returnTarget(),
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
        self.purpose = purpose
        isPrecisionMode = precisionMode
        // Never inherited from a previous overlay: a capture hotkey means "capture", and
        // arriving in colour-picking mode because of something you did ten minutes ago
        // would be baffling. It is on only when this call asked for it (docs/06 M22).
        isEyedropperMode = eyedropper
        self.freezes = Dictionary(uniqueKeysWithValues: freezes.map { ($0.geometry.displayID, $0) })
        pickableWindows = Self.mapWindows(windows, onto: freezes.map(\.geometry))
        previouslyActiveApp = ActivationJuggler.returnTarget(returningFocusTo)

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
        let descriptors = set.present()
        focusDisplayUnderPointer(descriptors)

        if let signpostState {
            signposter.endInterval("hotkeyToOverlay", signpostState)
        }
        logger.info("Selection overlay presented on \(set.windows.count, privacy: .public) display(s)")

        // Deliberately after the interval closes: finding the edges is a full pass over
        // every frozen bitmap, and the hotkey→overlay budget has no room for it (PRD §8).
        // The overlay is already usable; snapping switches on when the answer arrives.
        prepareSnapping(for: freezes)
    }

    /// Gives the keyboard to the display the pointer is on, and tells every display where
    /// the pointer is, so window mode highlights before the first move (T-CAP-2).
    private func focusDisplayUnderPointer(_ descriptors: [ScreenDescriptor]) {
        guard let windowSet else { return }
        let pointer = ScreenPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
        let target = Self.display(under: pointer, in: descriptors) ?? descriptors.first
        for descriptor in descriptors {
            guard let panel = windowSet.windows[descriptor.displayID] else { continue }
            if let local = descriptor.frame.topLeftLocalPoint(for: pointer) {
                panel.view.seedPointer(at: local)
            }
        }
        guard let target, let panel = windowSet.windows[target.displayID] else { return }
        panel.takeKeyboard()
        makeActive(displayID: target.displayID)
        detectEdges(forDisplay: target.displayID)
    }

    /// The display containing `pointer`, in AppKit screen space.
    public static func display(under pointer: ScreenPoint, in descriptors: [ScreenDescriptor]) -> ScreenDescriptor? {
        descriptors.first { $0.frame.contains(pointer) }
    }

    /// Remembers the frozen displays so their edges can be found when they are needed.
    ///
    /// Nothing is scanned here (docs/10 R1.6). Finding the edges of one 5K display costs
    /// about 68ms and a transient 14MB buffer — measured, and dominated by the greyscale
    /// conversion rather than the scan — and it used to happen for every display on every
    /// overlay, whether or not the user ever dragged near an edge. On a three-display Mac
    /// that is 200ms of CPU and 42MB churned for every screenshot somebody takes.
    private func prepareSnapping(for freezes: [FrozenDisplay]) {
        snapTask?.cancel()
        snapping = [:]
        scannedDisplays = []
        pendingFreezes = [:]
        guard snapsToEdges else { return }
        for frozen in freezes {
            pendingFreezes[frozen.geometry.displayID] = frozen
        }
    }

    /// Finds the straight edges in one display, off the main thread, once.
    ///
    /// Called when the pointer first enters a display, which is necessarily before anything
    /// can be dragged on it — so the work is done for the display being used and for no
    /// other, and it overlaps the moment the user spends deciding where to start.
    private func detectEdges(forDisplay displayID: CGDirectDisplayID) {
        guard snapsToEdges, !scannedDisplays.contains(displayID) else { return }
        guard let frozen = pendingFreezes[displayID] else { return }
        scannedDisplays.insert(displayID)

        let tolerance = snapTolerance
        let image = frozen.image
        let scale = frozen.geometry.scale.factor
        // Cancellable, because a second hotkey should abandon the work rather than finish
        // it for an overlay that is already gone.
        snapTask = Task { [weak self] in
            let candidates = await Task.detached(priority: .userInitiated) {
                EdgeDetector.candidates(in: image)
            }.value
            guard !Task.isCancelled else { return }
            self?.applySnapping(
                SelectionSnapping(candidates: candidates, scale: scale, tolerance: tolerance),
                to: displayID
            )
        }
    }

    private var pendingFreezes: [CGDirectDisplayID: FrozenDisplay] = [:]
    private var scannedDisplays: Set<CGDirectDisplayID> = []

    private func applySnapping(_ value: SelectionSnapping, to displayID: CGDirectDisplayID) {
        snapping[displayID] = value
        windowSet?.windows.values
            .first { $0.displayID == displayID }?
            .view.setSnapping(value)
    }

    /// Tears the overlay down without a selection.
    public func cancel() {
        dismiss(result: nil)
    }

    /// The frozen bitmaps currently on screen, for a later capture that should stay WYSIWYG
    /// (docs/03 §7: freeze, then capture normally).
    public var heldFreezes: [FrozenDisplay] {
        Array(freezes.values)
    }

    /// Dismisses without reporting cancel, so a follow-up capture can keep the frozen pixels.
    @discardableResult
    public func stealFreezesAndDismiss() -> [FrozenDisplay] {
        let held = Array(freezes.values)
        completion = nil
        if isPresented {
            dismiss(result: nil)
        }
        return held
    }

    /// Wires one panel's colour picking: the mode follows every display, and a pick
    /// answers before the overlay is torn down (docs/06 M22).
    private func configureEyedropper(on panel: SelectionPanel) {
        panel.view.setEyedropperMode(isEyedropperMode)
        panel.view.onEyedropperModeChanged = { [weak self] enabled in
            guard let self else { return }
            isEyedropperMode = enabled
            for panel in windowSet?.windows.values ?? [:].values {
                panel.view.setEyedropperMode(enabled)
            }
        }
        panel.view.onPickColor = { [weak self] pick in
            guard let self else { return }
            // Report before dismissing: tearing the overlay down drops the frozen bitmap
            // the pick was read out of.
            onColorPicked?(pick)
            dismiss(result: nil)
        }
    }

    /// Hands the overlay the windows it can pick once they arrive.
    ///
    /// An area overlay opens before the window list is fetched, so the hotkey-to-overlay
    /// budget does not wait on it; W then switches to window picking with the list in place
    /// (docs/18 CAP-1).
    public func updatePickableWindows(_ windows: [PickableWindowDescriptor]) {
        guard isPresented, let windowSet else { return }
        pickableWindows = Self.mapWindows(windows, onto: freezes.values.map(\.geometry))
        for (id, panel) in windowSet.windows {
            panel.view.setPickableWindows(pickableWindows[id] ?? [])
        }
    }

    private func makePanel(for descriptor: ScreenDescriptor) -> SelectionPanel? {
        guard let frozen = freezes[descriptor.displayID] else { return nil }
        let panel = SelectionPanel(frozen: frozen, screen: descriptor, mode: mode, purpose: currentPurpose)
        panel.view.setPickableWindows(pickableWindows[descriptor.displayID] ?? [])
        panel.view.setSnapping(snapping[descriptor.displayID])
        panel.view.setPrecisionMode(isPrecisionMode)
        panel.view.interaction.lockedAspect = lockedAspect
        panel.view.showsCaptureHints = showsCaptureHints
        panel.view.confirmsSelection = confirmsSelection
        panel.view.onCaptureDisplay = { [weak self] in
            self?.dismiss(result: .fullscreen(descriptor.displayID))
        }

        panel.view.onPrecisionModeChanged = { [weak self] enabled in
            guard let self else { return }
            isPrecisionMode = enabled
            for panel in windowSet?.windows.values ?? [:].values {
                panel.view.setPrecisionMode(enabled)
            }
            onPrecisionModeChanged?(enabled)
        }

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

        configureEyedropper(on: panel)

        if let lastRegion, lastRegion.displayID == descriptor.displayID {
            panel.view.lastRegionGhost = frozen.geometry.localRect(for: lastRegion.rect).cgRect
            panel.view.redraw()
        }

        panel.view.onCancel = { [weak self] in
            self?.dismiss(result: nil)
        }
        panel.view.onBecameActive = { [weak self] in
            self?.makeActive(displayID: descriptor.displayID)
            // The pointer is on this display, so a drag on it is now possible and its
            // edges are worth finding. No other display's are.
            self?.detectEdges(forDisplay: descriptor.displayID)
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

    private func applyLockedAspect() {
        guard let windowSet else { return }
        for panel in windowSet.windows.values {
            panel.view.interaction.lockedAspect = lockedAspect
        }
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
        // The deferred edge detection keeps its own reference to the frozen displays, and
        // a frozen 5K display is 14MB of bitmap. Leaving them here would make the overlay's
        // whole memory cost outlive the overlay — which is what the lifecycle test caught
        // the moment this cache was added.
        pendingFreezes.removeAll()
        snapTask?.cancel()
        pickableWindows.removeAll()

        // Hand focus back to whatever the user was in, so the overlay is invisible in
        // the app-switching sense as well as the visual one. Only if Kadr took it: the
        // panels are non-activating, so usually the user's app never lost it.
        ActivationJuggler.shared.yieldActivation(to: previouslyActiveApp)
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
