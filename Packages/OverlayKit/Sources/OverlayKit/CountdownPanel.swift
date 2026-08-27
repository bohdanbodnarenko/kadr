import AppKit
import Shared

/// The self-timer's countdown badge (docs/03 §1.5).
///
/// A floating, click-through panel in the top-right corner. Two properties matter for
/// correctness rather than looks:
///
/// * **`ignoresMouseEvents`** — the badge sits over whatever the user is arranging
///   before the shot, and must never intercept a click.
/// * **It belongs to Kadr**, so every capture path that excludes Kadr's own windows
///   keeps it out of the picture. Doc 03 §1.5 requires the badge never to appear in the
///   output, and excluding the app is how that is guaranteed rather than hoped for.
@MainActor
public final class CountdownPanel {
    private static let size = CGSize(width: 96, height: 96)
    private static let margin: CGFloat = 24

    private var panel: NonActivatingPanel?
    private let textLayer = CATextLayer()
    private let ringLayer = CAShapeLayer()

    public init() {}

    public var isVisible: Bool {
        panel != nil
    }

    /// Shows the badge on a screen, starting at `seconds`.
    public func show(on screen: NSScreen, seconds: Int) {
        guard panel == nil else {
            update(seconds: seconds)
            return
        }

        let frame = CGRect(
            x: screen.frame.maxX - Self.size.width - Self.margin,
            y: screen.frame.maxY - Self.size.height - Self.margin,
            width: Self.size.width,
            height: Self.size.height
        )

        let panel = NonActivatingPanel(contentRect: frame, level: .floating)
        panel.ignoresMouseEvents = true

        let view = NSView(frame: CGRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        guard let root = view.layer else { return }
        root.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        root.cornerRadius = Self.size.width / 2

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
        textLayer.alignmentMode = .center
        textLayer.contentsScale = screen.backingScaleFactor
        root.addSublayer(textLayer)

        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        update(seconds: seconds)
    }

    public func update(seconds: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = "\(max(0, seconds))"
        CATransaction.commit()
    }

    public func dismiss() {
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}
