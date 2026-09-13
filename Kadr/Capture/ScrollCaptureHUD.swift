import AppKit
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
            cancel: { [weak self] in self?.coordinator.cancel() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 360)

        let panel = NonActivatingPanel(
            contentRect: hosting.frame,
            // Above ordinary windows but below the selection overlay: the user is working
            // with the window underneath, not with this.
            level: .floating
        )
        panel.contentView = hosting
        panel.setFrame(frame(for: hosting.fittingSize), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Swaps the controls for a progress note while the helper works.
    func showStitching() {
        guard let hosting = panel?.contentView as? NSHostingView<ScrollCaptureHUDView> else { return }
        hosting.rootView.isStitching = true
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Sits beside the captured region rather than on top of it — covering the thing being
    /// captured would put the HUD in the capture.
    private func frame(for size: CGSize) -> NSRect {
        let screen = NSScreen.screens.first {
            $0.frame.intersects(anchor.cgRect)
        } ?? NSScreen.main
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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.15))
                    )
            }

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", action: cancel)
                    .disabled(isStitching)
                Spacer()
                Button("Stop", action: stop)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStitching)
            }
        }
        .padding(12)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: settings.scrollAxis == .vertical ? "arrow.down.doc" : "arrow.right.doc")
            Text(isStitching ? "Stitching…" : "Scrolling Capture")
                .font(.headline)
            Spacer()
            if coordinator.isAutoScrolling {
                Text("AUTO")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
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
        return "\(direction) the content, then press Stop. \(coordinator.frameCount) frames so far."
    }
}
