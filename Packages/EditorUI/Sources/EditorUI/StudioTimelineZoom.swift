import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// How the studio timeline stretches, and where it should stay pinned while it does.
///
/// Fit-to-window is not a working scale: a ten-minute recording across 800 points is 1.3
/// points per second, so a cut is a guess. Stretching has to keep the moment under the
/// pointer where it was — ⌘-scroll and pinch both hold that anchor — otherwise
/// zooming in on a cut shoves that cut off the screen and the user has to hunt for it.
enum StudioTimelineZoom {
    static let minimum: CGFloat = 1
    static let maximum: CGFloat = 60
    /// ⌘= / ⌘- step: five presses cover an order of magnitude.
    static let step: CGFloat = 1.6
    /// Trackpad points of ⌘-scroll that double the scale.
    static let scrollPointsPerDoubling: CGFloat = 220

    static func clamp(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, minimum), maximum)
    }

    /// Scale multiplier for one ⌘-scroll event. 1 means "ignore this tick".
    static func factor(fromScrollDelta delta: CGFloat, precise: Bool) -> CGFloat {
        let raw = precise ? delta : delta * 16
        guard abs(raw) > 0.001 else { return 1 }
        return CGFloat(pow(2, Double(raw / scrollPointsPerDoubling)))
    }

    /// 0…1 position of the pointer in the viewport, for `ScrollViewReader`'s anchor.
    static func viewportFraction(pointerX: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth > 0 else { return 0.5 }
        return min(max(pointerX / viewportWidth, 0), 1)
    }

    /// Content origin that keeps `time` under `pointerX` after the scale change.
    ///
    /// The SwiftUI timeline uses `scrollTo` with a unit point rather than setting this
    /// directly; the two agree when the identified view is a 1-point marker at `time`.
    static func scrollOrigin(
        keeping time: TimeInterval,
        atPointerX pointerX: CGFloat,
        scale: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        let contentX = CGFloat(time) * scale
        let proposed = contentX - pointerX
        let maxOrigin = max(0, contentWidth - viewportWidth)
        return min(max(proposed, 0), maxOrigin)
    }
}

/// Intercepts ⌘-scroll and pinch over the timeline viewport without stealing clicks.
///
/// SwiftUI's `ScrollView` eats two-finger pans, which we want, and has no hook for
/// "⌘-scroll means zoom around the pointer". A local monitor sees both, and `hitTest`
/// returning nil leaves trims, scrubs and the playhead crown to SwiftUI.
struct TimelineZoomCatcher: NSViewRepresentable {
    var onZoom: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onZoom = onZoom
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: Void) {
        view.stopMonitoring()
        view.onZoom = nil
    }

    final class CatcherView: NSView {
        var onZoom: ((CGFloat, CGFloat) -> Void)?
        private nonisolated(unsafe) var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), bounds.width > 0 else { return event }

            let factor: CGFloat
            switch event.type {
            case .scrollWheel:
                guard event.modifierFlags.contains(.command) else { return event }
                factor = StudioTimelineZoom.factor(
                    fromScrollDelta: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas
                )
            case .magnify:
                factor = 1 + CGFloat(event.magnification)
            default:
                return event
            }
            guard abs(factor - 1) > 0.0001 else { return nil }
            let pointerX = point.x
            MainActor.assumeIsolated {
                self.onZoom?(factor, pointerX)
            }
            return nil
        }
    }
}
