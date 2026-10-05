import AppKit
import OverlayKit
import SwiftUI

/// A one-time tip in a native popover (docs/03 §8.2).
///
/// `NSPopover`, as `QuickAccessCoachTip` already is: the arrow, the material, the open and
/// close animation and the placement that flips when there is no room are all AppKit's, and
/// match every other popover on the Mac. The content is SwiftUI in an `NSHostingController`
/// that reports its preferred size, so swapping a tour step animates the popover to the new
/// size instead of snapping.
///
/// Built on demand and released on close — no window, no view, no task while nothing is
/// showing (PRD §8).
@MainActor
final class CoachPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var host: NSHostingController<AnyView>?
    /// What the popover is anchored to, so the keyboard can be handed back on close.
    private weak var anchorView: NSView?
    /// The app that was frontmost when the tip appeared, for tips anchored somewhere that
    /// cannot take the keyboard back, such as the menu-bar icon (docs/18 SH-8).
    private var previousApp: NSRunningApplication?
    /// Called once, however the popover goes away.
    var onClose: (() -> Void)?

    var isShowing: Bool {
        popover?.isShown ?? false
    }

    func show(_ content: some View, relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        guard popover == nil else {
            update(content)
            return
        }
        let host = NSHostingController(rootView: AnyView(content))
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        // Application-defined, not transient: Kadr is an accessory app that is almost never
        // active, and a transient popover would close the moment the app it is teaching
        // about is clicked.
        popover.behavior = .applicationDefined
        popover.animates = !AccessibilityChrome.reduceMotion
        popover.contentViewController = host
        popover.delegate = self
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
        self.popover = popover
        self.host = host
        anchorView = view
        previousApp = ActivationJuggler.returnTarget()
    }

    /// Swaps the content in place; the popover resizes itself around it.
    func update(_ content: some View) {
        host?.rootView = AnyView(content)
    }

    func close() {
        popover?.performClose(nil)
        // `performClose` animates and then calls `popoverDidClose`; an unshown popover
        // never does, so finish the teardown here too.
        if popover?.isShown != true {
            finish()
            return
        }
        // And if the animation's callback never comes, go anyway. `performClose` on a
        // popover belonging to an inactive app — which Kadr is for most of a tip's life —
        // can animate nowhere and report nothing, and a tip that will not leave is worse
        // than one that leaves abruptly.
        closeFallback?.cancel()
        closeFallback = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, popover != nil else { return }
            popover?.close()
            finish()
        }
    }

    /// Makes sure a closing tip is gone even if AppKit never says so.
    private var closeFallback: Task<Void, Never>?

    func popoverDidClose(_ notification: Notification) {
        finish()
    }

    private func finish() {
        closeFallback?.cancel()
        closeFallback = nil
        guard popover != nil else { return }
        popover?.contentViewController = nil
        popover?.delegate = nil
        popover = nil
        host = nil
        returnKeyboardToAnchor()
        let callback = onClose
        onClose = nil
        callback?()
    }

    /// Gives the keyboard back to whatever the tip was pointing at.
    ///
    /// A popover runs in a window of its own and takes key status with it, so while a tip is
    /// up the island answers none of the keys the tip is teaching — and nothing handed focus
    /// back afterwards. Only for a window still on screen: a tip that closes because the
    /// island is going away must not order it front again.
    private func returnKeyboardToAnchor() {
        let previous = previousApp
        previousApp = nil
        guard let window = anchorView?.window, window.isVisible, window.canBecomeKey else {
            // The menu-bar coach: its anchor is the status bar, which cannot be key, so
            // the keyboard goes back to the app the user was in (docs/18 SH-8).
            anchorView = nil
            ActivationJuggler.shared.yieldActivation(to: previous)
            return
        }
        anchorView = nil
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }
}

/// A key as the Mac draws one in a menu: a quiet cap beside its meaning.
struct CoachKeycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator))
            .fixedSize()
    }
}

/// One line of a tip: a key (or a symbol) and what it does.
struct CoachRow: View {
    var key: String?
    var symbol: String?
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let key {
                    CoachKeycap(key: key)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 44, alignment: .center)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The dismiss control every tip carries in its corner.
struct CoachCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Don't show this again")
        .accessibilityLabel("Dismiss tip")
    }
}
