import AppKit
import Shared

/// Semantic sibling for a CALayer-only selection overlay (docs/14 UX-17B).
///
/// VoiceOver reads mode, dimensions and actions from here; the mouse path stays layers.
@MainActor
final class SelectionOverlayAccessibilityElement: NSAccessibilityElement {
    private weak var owner: SelectionOverlayView?

    init(owner: SelectionOverlayView) {
        self.owner = owner
        super.init()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture selection")
    }

    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window else { return .zero }
        return window.convertToScreen(owner.bounds)
    }

    override func accessibilityChildren() -> [Any]? {
        nil
    }

    func refresh(from view: SelectionOverlayView) {
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

    var accessibilityPhaseToken: String {
        [
            mode == .area ? "area" : "window",
            String(describing: interaction.phase),
            windowPick.hovered.map(\.label) ?? "",
            interaction.rect.map { DimensionFormatter.text(for: $0, scale: displayScale) } ?? ""
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
