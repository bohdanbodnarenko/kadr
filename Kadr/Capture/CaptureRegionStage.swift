import AppKit
import OverlayKit
import Shared
import SwiftUI

/// The chosen area, staged before anything starts (docs/03 §1.6, §1.8).
///
/// Selecting an area for a recording or a scrolling capture used to jump straight on — to
/// the recorder island with the area armed but nowhere to be seen, or straight into
/// grabbing frames. Nobody could check what they had picked, and a scrolling capture could
/// not be lined up first. This keeps the live screen visible inside the area, dims the rest,
/// and puts the one button that starts it in the middle of the area itself.
///
/// Two windows, deliberately. The dim is click-through (`RecordingAreaHighlight`, the same
/// one a region recording shows), so the page under it can still be scrolled into place.
/// Only the small control panel takes clicks and keys: Return starts, Escape backs out.
@MainActor
final class CaptureRegionStage {
    enum Purpose {
        case recording
        case scrolling

        var title: String {
            switch self {
            case .recording: KadrText.string("Record")
            case .scrolling: KadrText.string("Start Scrolling Capture")
            }
        }

        var symbol: String {
            switch self {
            case .recording: "record.circle.fill"
            case .scrolling: "arrow.down.doc"
            }
        }

        var hint: String {
            switch self {
            case .recording: KadrText.string("Return to record · Esc to choose again")
            case .scrolling: KadrText.string("Bar moves it · edges resize · scroll the page to the start")
            }
        }

        var cancelTitle: String {
            switch self {
            case .recording: KadrText.string("Clear area")
            case .scrolling: KadrText.string("Cancel")
            }
        }
    }

    private let dim = RecordingAreaHighlight()
    private var controls: NonActivatingPanel?
    private var keyMonitor: Any?

    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}

    var isShowing: Bool {
        dim.isShowing
    }

    nonisolated static let margin: CGFloat = 16

    func present(region: DisplayRect, displayID: CGDirectDisplayID, purpose: Purpose) {
        dismiss()
        dim.show(region: region, displayID: displayID)

        let hole = region.inScreenSpace(GlobalCoordinateSpace.current).cgRect
        let screen = NSScreen.screens.first { $0.frame.intersects(hole) } ?? ActiveScreen.resolve()
        let scale = screen?.backingScaleFactor ?? 2
        let view = CaptureRegionStageView(
            purpose: purpose,
            pixelSize: CGSize(width: hole.width * scale, height: hole.height * scale),
            start: { [weak self] in self?.start() },
            cancel: { [weak self] in self?.cancel() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = .intrinsicContentSize
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NonActivatingPanel(contentRect: hosting.frame, level: .floating)
        panel.alwaysHiddenFromCaptures = true
        panel.contentView = hosting
        panel.setFrame(
            Self.controlFrame(size: size, hole: hole, visible: screen?.visibleFrame ?? hole),
            display: false
        )
        panel.makeKeyAndOrderFront(nil)
        // A recording must not start with Kadr frontmost: the app being recorded would
        // begin the take inactive, grey traffic lights and all, and the first click spent
        // taking focus back would be in the file (docs/17 T-REC-6). The non-activating
        // panel takes the keyboard without activating the app, so Return and Esc still work.
        if purpose != .recording {
            NSApp.activate(ignoringOtherApps: true)
        }
        controls = panel
        installKeyMonitor()
    }

    /// Takes the button away and keeps the dim, for a capture that is now running.
    func keepDimOnly() {
        removeControls()
    }

    func dismiss() {
        removeControls()
        dim.hide()
    }

    private func start() {
        removeControls()
        onStart()
    }

    private func cancel() {
        dismiss()
        onCancel()
    }

    private func removeControls() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        controls?.orderOut(nil)
        controls?.contentView = nil
        controls = nil
    }

    /// Return and Escape while the stage is up. A local monitor, so nothing is read
    /// from other apps — the panel is key while it is showing.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, controls != nil else { return event }
            switch event.keyCode {
            case 36, 76:
                start()
                return nil
            case 53:
                cancel()
                return nil
            default:
                return event
            }
        }
    }

    /// Centred in the area when it fits there with a margin; otherwise just below it, then
    /// just above it, and always on the visible part of the screen.
    ///
    /// All rects are global AppKit coordinates (bottom-left origin).
    nonisolated static func controlFrame(size: CGSize, hole: CGRect, visible: CGRect) -> CGRect {
        let fitsInside = hole.width >= size.width + margin * 2 && hole.height >= size.height + margin * 2
        var origin = if fitsInside {
            CGPoint(x: hole.midX - size.width / 2, y: hole.midY - size.height / 2)
        } else if hole.minY - margin - size.height >= visible.minY {
            CGPoint(x: hole.midX - size.width / 2, y: hole.minY - margin - size.height)
        } else {
            CGPoint(x: hole.midX - size.width / 2, y: hole.maxY + margin)
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        return CGRect(origin: origin, size: size)
    }
}

/// The button in the middle of the staged area, with the area's size and the keys.
struct CaptureRegionStageView: View {
    let purpose: CaptureRegionStage.Purpose
    let pixelSize: CGSize
    let start: () -> Void
    let cancel: () -> Void
    /// Start, with Kadr doing the scrolling. Only scrolling capture offers one.
    var startAuto: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Button(action: start) {
                Label(purpose.title, systemImage: purpose.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(purpose == .recording ? Color(nsColor: .systemRed) : .accentColor)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if let startAuto {
                Button(action: startAuto) {
                    Label("Auto Scroll to the End", systemImage: "play.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .option)
                .help("Kadr scrolls the page itself and stops when it runs out (⌥↩)")
            }

            Text("\(Int(pixelSize.width.rounded())) × \(Int(pixelSize.height.rounded())) px")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(purpose.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button(purpose.cancelTitle, action: cancel)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .fixedSize()
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .kadrLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(purpose.title)
    }
}
