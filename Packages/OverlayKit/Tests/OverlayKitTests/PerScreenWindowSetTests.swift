import AppKit
import Shared
import Testing
@testable import OverlayKit

@MainActor
private final class FakeWindow: OverlayWindowing {
    private(set) var presentedOn: [ScreenDescriptor] = []
    private(set) var dismissCount = 0

    func present(on screen: ScreenDescriptor) {
        presentedOn.append(screen)
    }

    func dismiss() {
        dismissCount += 1
    }
}

@MainActor
private final class FakeScreens: ScreenProviding {
    var descriptors: [ScreenDescriptor]

    init(_ descriptors: [ScreenDescriptor]) {
        self.descriptors = descriptors
    }

    func currentScreens() -> [ScreenDescriptor] {
        descriptors
    }

    func screen(for descriptor: ScreenDescriptor) -> NSScreen? {
        nil
    }
}

private func descriptor(_ id: CGDirectDisplayID, width: CGFloat = 1920, scale: CGFloat = 2) -> ScreenDescriptor {
    ScreenDescriptor(
        displayID: id,
        frame: ScreenRect(x: 0, y: 0, width: width, height: 1080),
        backingScaleFactor: scale
    )
}

@MainActor
@Suite("Per-screen window set")
struct PerScreenWindowSetTests {
    private func makeSet(_ screens: FakeScreens) -> (PerScreenWindowSet<FakeWindow>, () -> [FakeWindow]) {
        var made: [FakeWindow] = []
        let set = PerScreenWindowSet(screens: screens) { _ in
            let window = FakeWindow()
            made.append(window)
            return window
        }
        return (set, { made })
    }

    @Test("One window per display")
    func oneWindowPerDisplay() {
        let screens = FakeScreens([descriptor(1), descriptor(2)])
        let (set, _) = makeSet(screens)

        set.present()

        #expect(set.windows.count == 2)
        #expect(set.window(for: 1) != nil)
        #expect(set.window(for: 2) != nil)
        #expect(set.isPresented)
    }

    @Test("Dismissing releases every window")
    func dismissReleasesEverything() {
        let screens = FakeScreens([descriptor(1), descriptor(2)])
        let (set, made) = makeSet(screens)
        set.present()
        set.dismiss()

        #expect(set.windows.isEmpty)
        #expect(set.isPresented == false)
        #expect(made().allSatisfy { $0.dismissCount == 1 })
    }

    @Test("A display that appears mid-overlay gets a window")
    func hotPlugAdds() {
        let screens = FakeScreens([descriptor(1)])
        let (set, _) = makeSet(screens)
        set.present()

        screens.descriptors = [descriptor(1), descriptor(2)]
        set.reconcileScreens()

        #expect(set.windows.count == 2)
        #expect(set.window(for: 2) != nil)
    }

    @Test("A display that goes away takes its window with it")
    func hotUnplugRemoves() {
        let screens = FakeScreens([descriptor(1), descriptor(2)])
        let (set, _) = makeSet(screens)
        set.present()
        let departing = set.window(for: 2)

        screens.descriptors = [descriptor(1)]
        set.reconcileScreens()

        #expect(set.windows.count == 1)
        #expect(set.window(for: 2) == nil)
        #expect(departing?.dismissCount == 1)
    }

    @Test("A resolution change repositions the existing window rather than making a new one")
    func resolutionChangeRepositions() {
        let screens = FakeScreens([descriptor(1, width: 1920)])
        let (set, made) = makeSet(screens)
        set.present()

        screens.descriptors = [descriptor(1, width: 2560)]
        set.reconcileScreens()

        #expect(made().count == 1, "a resolution change must not create a second panel")
        #expect(set.window(for: 1)?.presentedOn.last?.frame.width == 2560)
    }

    @Test("Reconciling reports the new display set to its owner")
    func reportsScreenChanges() {
        let screens = FakeScreens([descriptor(1)])
        let (set, _) = makeSet(screens)
        var reported: [ScreenDescriptor]?
        set.onScreensChanged = { reported = $0 }
        set.present()

        screens.descriptors = [descriptor(1), descriptor(2)]
        set.reconcileScreens()

        #expect(reported?.count == 2)
    }

    @Test("Reconciling a dismissed set does nothing")
    func reconcileWhenDismissed() {
        let screens = FakeScreens([descriptor(1)])
        let (set, made) = makeSet(screens)
        set.reconcileScreens()

        #expect(made().isEmpty)
        #expect(set.isPresented == false)
    }
}
