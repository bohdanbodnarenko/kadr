import AppKit
import Shared

/// The idle teaching pill on the freeze overlay (docs/03 §1.1).
///
/// A CALayer group so the 120 Hz mouse path never evaluates SwiftUI. Hidden the moment a
/// drag produces a rectangle, because the dimension badge then does the talking.
@MainActor
final class HintLayerGroup {
    let container = CALayer()
    private let background = CALayer()
    private let textLayer = CATextLayer()
    private let scale: DisplayScale

    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let padding = NSSize(width: 16, height: 10)

    init(scale: DisplayScale) {
        self.scale = scale
        container.isHidden = true
        background.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        background.cornerRadius = 8
        container.addSublayer(background)

        textLayer.font = Self.font
        textLayer.fontSize = 13
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = scale.factor
        container.addSublayer(textLayer)
    }

    func update(context: CaptureHintContext, in bounds: CGRect) {
        guard context.isEnabled, let copy = CaptureHintCopy.text(
            purpose: context.purpose,
            mode: context.mode,
            phase: context.phase,
            isEyedropper: context.isEyedropper
        ) else {
            container.isHidden = true
            return
        }

        let width = ceil(NSAttributedString(
            string: copy,
            attributes: [.font: Self.font]
        ).size().width) + Self.padding.width * 2
        let height: CGFloat = 32
        let frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        container.frame = frame
        background.frame = CGRect(origin: .zero, size: frame.size)
        textLayer.string = copy
        textLayer.frame = CGRect(
            x: 0,
            y: (height - 18) / 2,
            width: width,
            height: 18
        )
        container.isHidden = false
    }

    func hide() {
        container.isHidden = true
    }
}

/// Inputs the idle pill needs, grouped so `update` stays under the parameter-count lint.
struct CaptureHintContext {
    var purpose: SelectionPurpose
    var mode: SelectionOverlayView.Mode
    var phase: SelectionInteraction.Phase
    var isEyedropper: Bool
    var isEnabled: Bool
}

/// The overlay's teaching lines, as copy rather than layers so they can be tested.
enum CaptureHintCopy {
    static func text(
        purpose: SelectionPurpose,
        mode: SelectionOverlayView.Mode,
        phase: SelectionInteraction.Phase,
        isEyedropper: Bool
    ) -> String? {
        if isEyedropper {
            return "Click to copy  ·  F changes format  ·  X compares  ·  E leaves"
        }
        switch mode {
        case .window:
            return windowCopy(purpose)
        case .area:
            return areaCopy(purpose, phase: phase)
        }
    }

    private static func windowCopy(_ purpose: SelectionPurpose) -> String {
        switch purpose {
        case .recognizeText: "Click a window  ·  Tab to cycle  ·  A for a region"
        case .scrollingCapture: "Click the window to scroll  ·  Tab to cycle  ·  A for a region"
        case .inspect, .capture: "Click a window  ·  Tab to cycle  ·  A for a region"
        }
    }

    private static func areaCopy(_ purpose: SelectionPurpose, phase: SelectionInteraction.Phase) -> String? {
        switch phase {
        case .dragging:
            "Hold Space to move  ·  type width × height"
        case .selected:
            nil
        case .idle:
            switch purpose {
            case .recognizeText: "Drag the text  ·  W for a window"
            case .scrollingCapture: "Drag the region to scroll  ·  W for a window"
            case .inspect: "Drag a region from the freeze  ·  Esc to leave"
            case .capture: "Drag to select  ·  W for a window  ·  F for this display"
            }
        }
    }
}
