import AppKit
import OverlayKit
import SettingsKit
import SwiftUI

/// Copy for the collapsed overlay tab (docs/03 §2).
enum OverlayPeekCopy {
    static func title(count: Int, hasVideo: Bool) -> String {
        let noun = hasVideo ? "Capture" : "Screenshot"
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

/// The collapsed overlay: a pill in the same corner as the cards (docs/03 §2).
///
/// Cards hide rather than squash when the editor opens. This tab stays put so there is
/// no hide-and-restore race — click it to bring the stack back, even while the editor
/// is still open; the × dismisses every card without deleting files.
@MainActor
final class QuickAccessPeekPanel: NonActivatingPanel, InteractivelyMasked {
    private let hostingView: OverlayHostingView
    private var onExpand: () -> Void
    private var onDismissAll: () -> Void

    init(
        width: CGFloat,
        corner: OverlayCorner,
        title: String,
        onExpand: @escaping () -> Void,
        onDismissAll: @escaping () -> Void
    ) {
        self.onExpand = onExpand
        self.onDismissAll = onDismissAll
        hostingView = OverlayHostingView(rootView: QuickAccessPeekTabView(
            title: title,
            corner: corner,
            onExpand: onExpand,
            onDismissAll: onDismissAll
        ))

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: width, height: QuickAccessPeekTabView.pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureAsOverlay(level: .floating)
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        contentView = hostingView
    }

    func show(at origin: CGPoint) {
        setFrameOrigin(origin)
        orderFrontRegardless()
        CaptureExclusionRegistry.shared.register(self)
        InteractiveRegionTracker.shared.register(self)
    }

    func hide() {
        InteractiveRegionTracker.shared.unregister(self)
        orderOut(nil)
    }

    func teardown() {
        InteractiveRegionTracker.shared.unregister(self)
        CaptureExclusionRegistry.shared.unregister(self)
        contentView = nil
        orderOut(nil)
        close()
    }

    func update(title: String, corner: OverlayCorner, size: CGSize) {
        hostingView.setRootView(QuickAccessPeekTabView(
            title: title,
            corner: corner,
            onExpand: onExpand,
            onDismissAll: onDismissAll
        ))
        setFrame(
            CGRect(x: frame.minX, y: frame.minY, width: size.width, height: size.height),
            display: true
        )
        InteractiveRegionTracker.shared.update(at: NSEvent.mouseLocation)
    }

    var interactiveRegions: InteractiveRegions {
        InteractiveRegions(rects: [frame])
    }

    var passesMouseThrough: Bool {
        get { ignoresMouseEvents }
        set { ignoresMouseEvents = newValue }
    }
}

/// A pill the same width as the cards, docked to the configured corner.
struct QuickAccessPeekTabView: View {
    static let pillHeight: CGFloat = 42

    let title: String
    let corner: OverlayCorner
    let onExpand: () -> Void
    let onDismissAll: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onExpand) {
                HStack(spacing: 7) {
                    Image(systemName: corner.isBottom ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show recent captures")

            Divider()
                .frame(height: 14)

            peekDismissButton
                .padding(.trailing, 6)
        }
        .background(.regularMaterial, in: shape)
        .overlay {
            shape
                .strokeBorder(Color.primary.opacity(0.12))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). Show recent captures")
    }

    private var peekDismissButton: some View {
        Button(action: onDismissAll) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hide all — files stay")
        .accessibilityLabel("Hide all cards")
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: corner.isBottom ? 14 : 0,
            bottomLeadingRadius: corner.isBottom ? 0 : 14,
            bottomTrailingRadius: corner.isBottom ? 0 : 14,
            topTrailingRadius: corner.isBottom ? 14 : 0,
            style: .continuous
        )
    }
}
