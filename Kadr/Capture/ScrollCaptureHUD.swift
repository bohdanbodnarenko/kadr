import AppKit
import ControlKit
import OverlayKit
import SettingsKit
import Shared
import SwiftUI

/// The panel shown while a scrolling capture is running (docs/03 §1.6).
///
/// A non-activating panel, which matters more here than anywhere else in the app: the
/// user has to keep scrolling the window behind it, so this must never take focus or the
/// scroll wheel would go to the wrong place.
@MainActor
final class ScrollCaptureHUD {
    private let coordinator: ScrollCaptureCoordinator
    private let settings: AppSettings
    private let anchor: ScreenRect
    private var panel: NonActivatingPanel?
    /// Return and Escape both finish, with the page behind still in the user's hands. Escape
    /// does not discard: the user is working in that page, and an Esc meant for its find bar
    /// or cookie banner must not destroy a long capture (docs/18 CAP-2). Discarding is the
    /// Cancel button's job alone.
    private let keys = TransientHotKeys()

    private static let width: CGFloat = 240
    private static let margin: CGFloat = 16

    init(coordinator: ScrollCaptureCoordinator, settings: AppSettings, near anchor: ScreenRect) {
        self.coordinator = coordinator
        self.settings = settings
        self.anchor = anchor
    }

    func present() {
        let view = ScrollCaptureHUDView(
            coordinator: coordinator,
            settings: settings,
            stop: { [weak self] in self?.coordinator.stop() },
            cancel: { [weak self] in self?.coordinator.cancel() },
            toggleAuto: { [weak self] in
                guard let self else { return }
                if coordinator.isAutoScrolling {
                    coordinator.stopAutoScroll()
                } else {
                    coordinator.beginAutoScroll()
                }
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 360)

        let panel = NonActivatingPanel(
            contentRect: hosting.frame,
            // Above ordinary windows but below the selection overlay: the user is working
            // with the window underneath, not with this.
            level: .floating
        )
        panel.alwaysHiddenFromCaptures = true
        panel.contentView = hosting
        panel.setFrame(frame(for: hosting.fittingSize), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        keys.start([
            .escape: { [weak self] in self?.coordinator.stop() },
            .returnKey: { [weak self] in self?.coordinator.stop() },
            .enter: { [weak self] in self?.coordinator.stop() }
        ])
    }

    /// Swaps the controls for a progress note while the helper works.
    func showStitching() {
        // The keys are for the capture, not for the stitch: left live, Return would miss
        // the alert's default button and Esc would act on frames it is offering to export
        // (docs/18 CAP-7).
        keys.stop()
        guard let hosting = panel?.contentView as? NSHostingView<ScrollCaptureHUDView> else { return }
        hosting.rootView.isStitching = true
    }

    func dismiss() {
        keys.stop()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Sits beside the captured region rather than on top of it — covering the thing being
    /// captured would put the HUD in the capture.
    private func frame(for size: CGSize) -> NSRect {
        let screen = NSScreen.screens.first {
            $0.frame.intersects(anchor.cgRect)
        } ?? ActiveScreen.resolve()
        let visible = screen?.visibleFrame ?? .zero

        let toTheRight = anchor.maxX + Self.margin
        let x = toTheRight + size.width < visible.maxX
            ? toTheRight
            : max(visible.minX + Self.margin, anchor.minX - size.width - Self.margin)
        let y = min(
            max(visible.minY + Self.margin, anchor.maxY - size.height),
            visible.maxY - size.height - Self.margin
        )
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// The HUD's content: the growing strip, the frame count, and the way out (docs/03 §1.6).
struct ScrollCaptureHUDView: View {
    let coordinator: ScrollCaptureCoordinator
    @Bindable var settings: AppSettings
    let stop: () -> Void
    let cancel: () -> Void
    let toggleAuto: () -> Void
    var isStitching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Picker("Direction", selection: $settings.scrollAxis) {
                ForEach(ScrollAxis.allCases, id: \.self) { axis in
                    Text(axis.title).tag(axis)
                }
            }
            .pickerStyle(.segmented)
            .disabled(coordinator.frameCount > 0 || isStitching)

            if let preview = coordinator.preview {
                Image(decorative: preview, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: KadrRadius.medium))
                    .overlay(
                        RoundedRectangle(cornerRadius: KadrRadius.medium)
                            .strokeBorder(KadrFill.stroke)
                    )
            }

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            autoButton

            HStack {
                Button("Cancel", action: cancel)
                    .disabled(isStitching)
                Spacer()
                Button("Stop", action: stop)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStitching)
            }
        }
        .padding(KadrSpace.large)
        .frame(width: 240)
        .kadrLiquidGlass(in: RoundedRectangle(cornerRadius: KadrRadius.panel, style: .continuous), interactive: true)
    }

    /// Hands the scrolling to Kadr, and back again.
    ///
    /// Full width and above the Cancel / Stop row: it is the thing most people came for,
    /// and it used to be reachable only by finding a checkbox in Settings ▸ Capture before
    /// starting the capture.
    private var autoButton: some View {
        Button(action: toggleAuto) {
            Label(
                coordinator.isAutoScrolling ? "Scrolling — Take Over" : "Auto Scroll",
                systemImage: coordinator.isAutoScrolling ? "hand.raised" : "play.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(isStitching || (!coordinator.isAutoScrolling && !coordinator.canAutoScroll))
        .help(coordinator.isAutoScrolling
            ? "Stop scrolling for me — I'll carry on by hand"
            : "Kadr scrolls to the end of the page on its own")
        .accessibilityHint("Kadr scrolls the page itself, and stops when the page runs out")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: settings.scrollAxis == .vertical ? "arrow.down.doc" : "arrow.right.doc")
            Text(isStitching ? "Stitching…" : "Scrolling Capture")
                .font(.headline)
            Spacer()
            if coordinator.isAutoScrolling {
                Text("AUTO")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, KadrSpace.xxs)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
            }
        }
    }

    private var status: String {
        let direction = settings.scrollAxis == .vertical ? "Scroll" : "Scroll sideways"
        if isStitching {
            return "Joining \(coordinator.frameCount) frames into one page."
        }
        if coordinator.isAutoScrolling {
            return "Kadr is scrolling. It stops on its own when the page runs out. "
                + "\(coordinator.frameCount) frames so far."
        }
        return "\(direction) the content, then press Stop (Return or Esc). "
            + "\(coordinator.frameCount) frames so far."
    }
}
