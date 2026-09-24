import AppKit
import Foundation
import Testing
@testable import OverlayKit

/// Which parts of a floating panel take clicks (docs/09 U2.1).
///
/// The behaviour worth pinning is the one users notice: an overlay that swallows clicks
/// over its padding is the single most irritating thing a floating window can do, and the
/// rule that fixes it is small enough to state exactly.
@Suite("Interactive regions")
struct InteractiveRegionsTests {
    private let button = CGRect(x: 100, y: 100, width: 40, height: 20)
    private let thumbnail = CGRect(x: 100, y: 140, width: 200, height: 120)

    private var regions: InteractiveRegions {
        InteractiveRegions(rects: [button, thumbnail])
    }

    @Test("A point on a control is interactive")
    func pointOnAControl() {
        #expect(regions.containsInteractiveContent(at: CGPoint(x: 110, y: 110)))
        #expect(!regions.shouldPassThrough(at: CGPoint(x: 110, y: 110)))
    }

    @Test("A point in the padding passes through")
    func pointInPadding() {
        #expect(regions.shouldPassThrough(at: CGPoint(x: 400, y: 400)))
    }

    /// The empty case matters: a panel with nothing interactive is a panel that should be
    /// invisible to the mouse entirely.
    @Test("A panel with no controls passes everything through")
    func noRegions() {
        #expect(InteractiveRegions.none.shouldPassThrough(at: .zero))
        #expect(!InteractiveRegions.none.containsInteractiveContent(at: .zero))
    }

    /// A hit target the exact size of the drawn control is one the user misses: the
    /// pointer arrives a pixel early and the click lands in the app behind.
    @Test("Targets are forgiving at their edges")
    func slopMakesTargetsForgiving() {
        let justOutside = CGPoint(x: button.minX - 1, y: button.midY)
        #expect(regions.shouldPassThrough(at: justOutside))
        #expect(!regions.expanded(by: 2).shouldPassThrough(at: justOutside))
    }

    @Test("Slop grows every rect on every side")
    func slopIsSymmetric() {
        let grown = InteractiveRegions(rects: [button]).expanded(by: 5)
        #expect(grown.rects[0] == button.insetBy(dx: -5, dy: -5))
    }

    @Test("Overlapping controls are still one interactive area")
    func overlappingRects() {
        let overlapping = InteractiveRegions(rects: [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 50, y: 50, width: 100, height: 100)
        ])
        #expect(overlapping.containsInteractiveContent(at: CGPoint(x: 75, y: 75)))
        #expect(overlapping.containsInteractiveContent(at: CGPoint(x: 140, y: 140)))
        #expect(overlapping.shouldPassThrough(at: CGPoint(x: 200, y: 200)))
    }
}

/// The windows a capture must not photograph (docs/09 U2.1).
@MainActor
@Suite("Capture exclusion registry")
struct CaptureExclusionRegistryTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("A fresh registry excludes nothing")
    func emptyRegistry() {
        #expect(CaptureExclusionRegistry().isEmpty)
        #expect(CaptureExclusionRegistry().excludedWindowIDs.isEmpty)
    }

    @Test("A registered window is excluded")
    func registering() {
        let registry = CaptureExclusionRegistry()
        let window = makeWindow()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        registry.register(window)
        #expect(!registry.isEmpty)
        #expect(registry.excludedWindowIDs.contains(CGWindowID(window.windowNumber)))
    }

    @Test("Include Kadr overlays reaches panels and the filter, except always-hidden ones (T-CAP-11)")
    func includeOverlaysSetting() {
        let previous = CaptureVisibility.includesOverlays
        defer { CaptureVisibility.includesOverlays = previous }
        CaptureVisibility.includesOverlays = true

        let registry = CaptureExclusionRegistry()
        let card = NonActivatingPanel(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        let selection = NonActivatingPanel(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        selection.alwaysHiddenFromCaptures = true
        card.orderFrontRegardless()
        selection.orderFrontRegardless()
        defer {
            card.orderOut(nil)
            selection.orderOut(nil)
        }
        registry.register(card)
        registry.register(selection)

        #expect(card.sharingType == .readOnly)
        #expect(selection.sharingType == .none, "set after init, and still applied")
        #expect(!registry.excludedWindowIDs.contains(CGWindowID(card.windowNumber)))
        #expect(registry.excludedWindowIDs.contains(CGWindowID(selection.windowNumber)))
    }

    @Test("Registering twice is harmless")
    func registeringTwice() {
        let registry = CaptureExclusionRegistry()
        let window = makeWindow()
        registry.register(window)
        registry.register(window)
        registry.unregister(window)
        #expect(registry.isEmpty)
    }

    @Test("Unregistering removes it again")
    func unregistering() {
        let registry = CaptureExclusionRegistry()
        let window = makeWindow()
        registry.register(window)
        registry.unregister(window)
        #expect(registry.isEmpty)
    }

    /// A registry that held its members would leak every overlay Kadr ever showed, and
    /// would keep excluding windows that no longer exist.
    @Test("A window that has gone is forgotten")
    func deadWindowsAreSwept() {
        let registry = CaptureExclusionRegistry()
        autoreleasepool {
            let window = makeWindow()
            registry.register(window)
            #expect(!registry.isEmpty)
        }
        // The window is gone; the registry must not still be holding it.
        #expect(registry.excludedWindowIDs.isEmpty)
    }

    /// The point of a registry rather than excluding the whole application: an ordinary
    /// window — Settings, the editor — is capturable, because nobody registered it.
    @Test("An unregistered window is capturable")
    func unregisteredWindowIsCapturable() {
        let registry = CaptureExclusionRegistry()
        let overlay = makeWindow()
        let settings = makeWindow()
        overlay.orderFrontRegardless()
        settings.orderFrontRegardless()
        defer {
            overlay.orderOut(nil)
            settings.orderOut(nil)
        }

        registry.register(overlay)
        #expect(registry.excludedWindowIDs.contains(CGWindowID(overlay.windowNumber)))
        #expect(!registry.excludedWindowIDs.contains(CGWindowID(settings.windowNumber)))
    }
}

/// The tracker that applies those regions (docs/09 U2.1).
@MainActor
@Suite("Interactive region tracker")
struct InteractiveRegionTrackerTests {
    private final class StubPanel: InteractivelyMasked {
        var interactiveRegions: InteractiveRegions
        var passesMouseThrough = false

        init(rects: [CGRect]) {
            interactiveRegions = InteractiveRegions(rects: rects)
        }
    }

    @Test("A pointer over a control makes the panel take events")
    func pointerOverAControl() {
        let tracker = InteractiveRegionTracker()
        let panel = StubPanel(rects: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        tracker.register(panel)

        tracker.update(at: CGPoint(x: 50, y: 50))
        #expect(!panel.passesMouseThrough)
    }

    @Test("A pointer elsewhere makes it disappear")
    func pointerElsewhere() {
        let tracker = InteractiveRegionTracker()
        let panel = StubPanel(rects: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        tracker.register(panel)

        tracker.update(at: CGPoint(x: 500, y: 500))
        #expect(panel.passesMouseThrough)
    }

    /// A panel on its way out must take events again, or its own teardown fights a
    /// pass-through nothing is updating any more.
    @Test("Unregistering restores the panel to taking events")
    func unregisteringRestores() {
        let tracker = InteractiveRegionTracker()
        let panel = StubPanel(rects: [CGRect(x: 0, y: 0, width: 10, height: 10)])
        tracker.register(panel)
        tracker.update(at: CGPoint(x: 500, y: 500))
        #expect(panel.passesMouseThrough)

        tracker.unregister(panel)
        #expect(!panel.passesMouseThrough)
    }

    @Test("Several panels are each judged on their own regions")
    func severalPanels() {
        let tracker = InteractiveRegionTracker()
        let left = StubPanel(rects: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        let right = StubPanel(rects: [CGRect(x: 200, y: 0, width: 100, height: 100)])
        tracker.register(left)
        tracker.register(right)

        tracker.update(at: CGPoint(x: 50, y: 50))
        #expect(!left.passesMouseThrough)
        #expect(right.passesMouseThrough)
    }

    @Test("A panel with no interactive regions never takes events")
    func inertPanel() {
        let tracker = InteractiveRegionTracker()
        let panel = StubPanel(rects: [])
        tracker.register(panel)

        tracker.update(at: .zero)
        #expect(panel.passesMouseThrough)
    }
}
