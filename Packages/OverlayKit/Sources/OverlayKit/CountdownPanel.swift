import AppKit
import Shared

/// Where the self-timer number sits on the screen.
///
/// Stills use the corner badge docs/03 §1.5 describes. Recordings use the centre so the
/// number is the thing you look at while the control bar stays a row of icons.
public enum CountdownPlacement: Sendable, Equatable {
    /// Top-right, small, out of the way of what is being arranged.
    case corner
    /// Middle of the screen, large enough to read from across the desk.
    case center
}

/// The self-timer's countdown badge (docs/03 §1.5).
///
/// A floating, click-through panel. Two properties matter for correctness rather than looks:
///
/// * **`ignoresMouseEvents`** — the badge sits over whatever the user is arranging
///   before the shot, and must never intercept a click.
/// * **It belongs to Kadr**, so every capture path that excludes registered overlay
///   windows keeps it out of the picture. Doc 03 §1.5 requires the badge never to appear
///   in the output; `NonActivatingPanel` registers itself on the capture-exclusion
///   registry when it comes on screen (docs/10 R3.2).
@MainActor
public final class CountdownPanel {
    private static let cornerSize = CGSize(width: 96, height: 96)
    private static let centerSize = CGSize(width: 160, height: 160)
    private static let margin: CGFloat = 24

    private var panel: NonActivatingPanel?
    private let textLayer = CATextLayer()
    private let ringLayer = CAShapeLayer()
    private var placement: CountdownPlacement = .corner

    public init() {}

    public var isVisible: Bool {
        panel != nil
    }

    /// The badge's content view, for `NSAccessibility.post` announcements (docs/14 UX-17B).
    ///
    /// The drawing stays CALayer-only; this is the element an announcement can be hung
    /// off, and the one VoiceOver reads when it lands on the panel.
    public var accessibilityElement: NSView? {
        panel?.contentView
    }

    /// Shows the badge on a screen, starting at `seconds`.
    public func show(
        on screen: NSScreen,
        seconds: Int,
        placement: CountdownPlacement = .corner
    ) {
        if panel != nil {
            if self.placement == placement {
                update(seconds: seconds)
                return
            }
            dismiss()
        }

        self.placement = placement
        let size = Self.size(for: placement)
        let frame = Self.frame(size: size, placement: placement, in: screen.frame)
        present(frame: frame, size: size, scale: screen.backingScaleFactor)
        update(seconds: seconds)
    }

    public func update(seconds: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = "\(max(0, seconds))"
        CATransaction.commit()
        panel?.contentView?.setAccessibilityValue(Self.accessibilityValue(seconds: seconds))
    }

    /// What VoiceOver reads for a given number, kept here so it can be tested without a panel.
    static func accessibilityValue(seconds: Int) -> String {
        let remaining = max(0, seconds)
        return remaining == 1 ? "1 second" : "\(remaining) seconds"
    }

    public func dismiss() {
        textLayer.removeFromSuperlayer()
        ringLayer.removeFromSuperlayer()
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// Layout in screen space, so a test can pin where the number lands without opening a window.
    static func frame(size: CGSize, placement: CountdownPlacement, in screen: CGRect) -> CGRect {
        switch placement {
        case .corner:
            CGRect(
                x: screen.maxX - size.width - margin,
                y: screen.maxY - size.height - margin,
                width: size.width,
                height: size.height
            )
        case .center:
            CGRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    static func size(for placement: CountdownPlacement) -> CGSize {
        switch placement {
        case .corner: cornerSize
        case .center: centerSize
        }
    }

    private func present(frame: CGRect, size: CGSize, scale: CGFloat) {
        let panel = NonActivatingPanel(contentRect: frame, level: .floating)
        panel.ignoresMouseEvents = true

        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        guard let root = view.layer else { return }
        installChrome(in: root, size: size, scale: scale)
        configureAccessibility(of: view)

        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// A one-element semantic sibling for a layer-drawn badge (docs/14 UX-17B).
    ///
    /// Static text rather than a button: the badge is not clickable — the panel ignores
    /// mouse events entirely — and the way out is the key named in the help.
    private func configureAccessibility(of view: NSView) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel("Countdown")
        view.setAccessibilityHelp("Press Escape to cancel")
    }

    private func installChrome(in root: CALayer, size: CGSize, scale: CGFloat) {
        switch placement {
        case .corner:
            installCornerChrome(in: root, size: size)
        case .center:
            installCenterChrome(in: root)
        }
        textLayer.alignmentMode = .center
        textLayer.contentsScale = scale
        root.addSublayer(textLayer)
    }

    private func installCornerChrome(in root: CALayer, size: CGSize) {
        root.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        root.cornerRadius = size.width / 2
        ringLayer.frame = root.bounds
        ringLayer.path = CGPath(
            ellipseIn: root.bounds.insetBy(dx: 6, dy: 6),
            transform: nil
        )
        ringLayer.fillColor = nil
        ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        ringLayer.lineWidth = 3
        root.addSublayer(ringLayer)
        textLayer.frame = root.bounds.insetBy(dx: 0, dy: 24)
        textLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        textLayer.fontSize = 40
        textLayer.foregroundColor = NSColor.white.cgColor
    }

    private func installCenterChrome(in root: CALayer) {
        root.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        root.cornerRadius = 28
        root.cornerCurve = .continuous
        textLayer.frame = root.bounds.insetBy(dx: 8, dy: 36)
        textLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        textLayer.fontSize = 72
        textLayer.foregroundColor = NSColor.white.cgColor
    }
}
