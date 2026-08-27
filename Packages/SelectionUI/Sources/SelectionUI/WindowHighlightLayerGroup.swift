import AppKit
import Shared

/// The hover highlight for window-pick mode: tint, outline and title chip (docs/03 §1.2).
@MainActor
final class WindowHighlightLayerGroup {
    private static let chipHeight: CGFloat = 24
    private static let chipInset: CGFloat = 10

    let container = CALayer()
    private let fillLayer = CAShapeLayer()
    private let chipBackground = CALayer()
    private let chipText = CATextLayer()
    private let chipFont: NSFont

    init(scale: DisplayScale) {
        chipFont = .systemFont(ofSize: 13, weight: .medium)

        container.isHidden = true

        fillLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        fillLayer.strokeColor = NSColor.controlAccentColor.cgColor
        fillLayer.lineWidth = 2
        container.addSublayer(fillLayer)

        chipBackground.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        chipBackground.cornerRadius = 6
        container.addSublayer(chipBackground)

        chipText.font = chipFont
        chipText.fontSize = chipFont.pointSize
        chipText.foregroundColor = NSColor.white.cgColor
        chipText.alignmentMode = .center
        chipText.truncationMode = .middle
        chipText.contentsScale = scale.factor
        container.addSublayer(chipText)
    }

    func hide() {
        container.isHidden = true
    }

    /// Highlights a window and places its title chip inside the frame.
    ///
    /// The chip goes *inside* the window rather than above it so it never covers the
    /// window behind, which would make the highlight ambiguous when windows are stacked.
    func show(_ window: PickableWindow, within bounds: CGRect) {
        container.isHidden = false

        let frame = window.frame.intersection(bounds)
        guard !frame.isEmpty else {
            hide()
            return
        }

        fillLayer.path = CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil)

        let label = window.label
        chipText.string = label
        let textWidth = ceil(NSAttributedString(
            string: label,
            attributes: [.font: chipFont]
        ).size().width)
        let chipWidth = min(frame.width - Self.chipInset * 2, textWidth + 20)

        guard chipWidth > 40 else {
            // Too small a window to label without covering it entirely.
            chipBackground.isHidden = true
            chipText.isHidden = true
            return
        }
        chipBackground.isHidden = false
        chipText.isHidden = false

        let chipFrame = CGRect(
            x: frame.midX - chipWidth / 2,
            y: frame.minY + Self.chipInset,
            width: chipWidth,
            height: Self.chipHeight
        )
        chipBackground.frame = chipFrame
        chipText.frame = chipFrame.insetBy(dx: 6, dy: 4)
    }
}
