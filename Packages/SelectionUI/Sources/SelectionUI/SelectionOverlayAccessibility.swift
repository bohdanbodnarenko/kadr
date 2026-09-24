import AppKit
import Shared

/// Semantic sibling for a CALayer-only selection overlay (docs/14 UX-17B).
///
/// VoiceOver reads mode, dimensions and actions from here; the mouse path stays layers.
@MainActor
final class SelectionOverlayAccessibilityElement: NSAccessibilityElement {
    /// VoiceOver can query the frame off the main actor; `refresh` writes this snapshot.
    private nonisolated(unsafe) var screenFrame: NSRect = .zero

    init(owner: SelectionOverlayView) {
        super.init()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture selection")
        snapshotFrame(from: owner)
    }

    override nonisolated func accessibilityFrame() -> NSRect {
        screenFrame
    }

    override func accessibilityChildren() -> [Any]? {
        nil
    }

    func refresh(from view: SelectionOverlayView) {
        snapshotFrame(from: view)
        setAccessibilityLabel(view.accessibilitySummaryLabel)
        setAccessibilityValue(view.accessibilitySummaryValue)
        setAccessibilityHelp(view.accessibilitySummaryHelp)
        setAccessibilityCustomActions(view.accessibilityActionDescriptors.map { descriptor in
            NSAccessibilityCustomAction(name: descriptor.title) { [weak view] in
                view?.performAccessibilityAction(descriptor.action)
                return true
            }
        })
    }

    private func snapshotFrame(from view: SelectionOverlayView) {
        if let window = view.window {
            screenFrame = window.convertToScreen(view.bounds)
        } else {
            screenFrame = .zero
        }
    }
}

extension SelectionOverlayView {
    enum AccessibilityAction: Equatable {
        case commit
        case cancel
        case switchMode
        case captureDisplay
    }

    struct AccessibilityActionDescriptor: Equatable {
        let title: String
        let action: AccessibilityAction
    }

    func installAccessibilityElement() {
        guard accessibilityProxy == nil else { return }
        accessibilityProxy = SelectionOverlayAccessibilityElement(owner: self)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func refreshAccessibilityElement(announcePhaseChange: Bool = false) {
        installAccessibilityElement()
        guard let element = accessibilityProxy else { return }
        let previousPhase = accessibilityAnnouncedPhase
        element.refresh(from: self)
        let phase = accessibilityPhaseToken
        guard announcePhaseChange, phase != previousPhase else { return }
        accessibilityAnnouncedPhase = phase
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: accessibilityPhaseAnnouncement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    var accessibilitySummaryLabel: String {
        switch mode {
        case .area:
            switch purpose {
            case .capture: "Area capture"
            case .recognizeText: "Capture text"
            case .scrollingCapture: "Scrolling capture"
            case .inspect: "Freeze and inspect"
            }
        case .window:
            "Window capture"
        }
    }

    var accessibilitySummaryValue: String? {
        if mode == .window, let window = windowPick.hovered {
            return window.label
        }
        guard let rect = interaction.rect, !rect.isEmpty else {
            if isEyedropperMode, let pointer = interaction.pointer {
                return String(format: "Pointer at %.0f, %.0f points", pointer.x, pointer.y)
            }
            return nil
        }
        return DimensionFormatter.text(for: rect, scale: displayScale)
    }

    var accessibilitySummaryHelp: String? {
        if confirmsSelection, interaction.phase == .selected {
            return "Press Return to capture, Escape to cancel"
        }
        switch mode {
        case .area:
            return "Drag to select. Press F to capture this display."
        case .window:
            return "Click a window. Hold Command to include panels. Tab cycles windows of the same app."
        }
    }

    var accessibilityActionDescriptors: [AccessibilityActionDescriptor] {
        var actions: [AccessibilityActionDescriptor] = [
            AccessibilityActionDescriptor(title: "Commit", action: .commit),
            AccessibilityActionDescriptor(title: "Cancel", action: .cancel)
        ]
        switch mode {
        case .area where purpose == .capture:
            actions.append(AccessibilityActionDescriptor(title: "Switch to window mode", action: .switchMode))
            actions.append(AccessibilityActionDescriptor(title: "Capture display", action: .captureDisplay))
        case .window:
            actions.append(AccessibilityActionDescriptor(title: "Switch to area mode", action: .switchMode))
        default:
            break
        }
        return actions
    }

    func performAccessibilityAction(_ action: AccessibilityAction) {
        switch action {
        case .commit:
            commitCurrentSelection()
        case .cancel:
            onCancel?()
        case .switchMode:
            let newMode: Mode = mode == .area ? .window : .area
            setMode(newMode)
            onModeChanged?(newMode)
        case .captureDisplay:
            onCaptureDisplay?()
        }
        refreshAccessibilityElement(announcePhaseChange: true)
    }

    /// What counts as a change worth announcing. Not the rect: it changes on every drag
    /// event, and announcing each one flooded VoiceOver (T-CAP-12).
    var accessibilityPhaseToken: String {
        [
            mode == .area ? "area" : "window",
            String(describing: interaction.phase),
            windowPick.hovered.map(\.label) ?? ""
        ].joined(separator: "|")
    }

    var accessibilityPhaseAnnouncement: String {
        if mode == .window, let window = windowPick.hovered {
            return window.label
        }
        if let rect = interaction.rect, !rect.isEmpty {
            return DimensionFormatter.text(for: rect, scale: displayScale)
        }
        return mode == .area ? "Area selection" : "Window selection"
    }

    func commitCurrentSelection() {
        if mode == .window, let window = windowPick.hovered {
            onCommitWindow?(window, false)
            return
        }
        if let rect = interaction.rect, !rect.isEmpty {
            onCommit?(rect)
        }
    }
}

extension SelectionOverlayView {
    override func isAccessibilityElement() -> Bool {
        false
    }

    override func accessibilityChildren() -> [Any]? {
        installAccessibilityElement()
        guard let accessibilityProxy else { return nil }
        return [accessibilityProxy]
    }
}
