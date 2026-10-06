import AppKit
import OverlayKit
import SelectionUI
import Shared
import Testing
@testable import Kadr

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

private func makeImage(width: Int, height: Int) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fatalError("Could not build a test bitmap")
    }
    return image
}

private func descriptor(_ id: CGDirectDisplayID) -> ScreenDescriptor {
    ScreenDescriptor(
        displayID: id,
        frame: ScreenRect(x: 0, y: 0, width: 400, height: 300),
        backingScaleFactor: 2
    )
}

private func frozen(_ id: CGDirectDisplayID) -> FrozenDisplay {
    FrozenDisplay(
        geometry: DisplayGeometry(
            displayID: id,
            frame: DisplayRect(x: 0, y: 0, width: 400, height: 300),
            scale: .retina
        ),
        image: makeImage(width: 800, height: 600)
    )
}

/// Drives the real overlay with synthetic freezes, so the panel lifecycle is covered
/// without a Screen Recording grant — the parts that need TCC are the pixels, not the
/// window management.
@MainActor
@Suite("Selection overlay lifecycle", .serialized)
struct SelectionOverlayLifecycleTests {
    @Test("Presenting puts the overlay up and cancelling takes it down with no result")
    func presentThenCancel() {
        let controller = SelectionOverlayController(screens: FakeScreens([descriptor(1)]))
        var completions = 0
        var outcome: SelectionOutcome?

        controller.present(freezes: [frozen(1)]) { selection in
            completions += 1
            outcome = selection
        }
        #expect(controller.isPresented)

        controller.cancel()

        #expect(controller.isPresented == false)
        #expect(completions == 1)
        #expect(outcome == nil, "cancelling must not produce a selection")
    }

    @Test("A second present replaces the first rather than stacking overlays")
    func secondPresentReplacesFirst() {
        let controller = SelectionOverlayController(screens: FakeScreens([descriptor(1)]))
        var completions = 0

        controller.present(freezes: [frozen(1)]) { _ in completions += 1 }
        controller.present(freezes: [frozen(1)]) { _ in completions += 1 }

        #expect(controller.isPresented)
        #expect(completions == 1, "the replaced overlay must resolve, not leak its completion")

        controller.cancel()
        #expect(completions == 2)
    }

    @Test("Every display gets an overlay")
    func onePanelPerDisplay() {
        let controller = SelectionOverlayController(screens: FakeScreens([descriptor(1), descriptor(2)]))
        controller.present(freezes: [frozen(1), frozen(2)]) { _ in }

        #expect(controller.isPresented)
        // Two borderless panels, and nothing else of ours on screen.
        let panels = NSApp.windows.filter { $0 is NSPanel && $0.isVisible }
        #expect(panels.count >= 2)

        controller.cancel()
    }

    @Test("Cancelling releases the frozen bitmaps — the overlay's whole memory cost")
    func cancelReleasesFrozenImages() async {
        let controller = SelectionOverlayController(screens: FakeScreens([descriptor(1)]))
        var image: CGImage? = makeImage(width: 800, height: 600)
        let probe: () -> AnyObject? = { [weak held = image] in held }

        controller.present(
            freezes: [FrozenDisplay(
                geometry: DisplayGeometry(
                    displayID: 1,
                    frame: DisplayRect(x: 0, y: 0, width: 400, height: 300),
                    scale: .retina
                ),
                image: image ?? makeImage(width: 1, height: 1)
            )]
        ) { _ in }

        controller.cancel()
        image = nil

        var freed = false
        for _ in 0 ..< 50 {
            if probe() == nil {
                freed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(freed, "a frozen display bitmap outlived the overlay")
    }

    @Test("Dismissing an overlay that was never presented is harmless")
    func cancelWithoutPresent() {
        let controller = SelectionOverlayController(screens: FakeScreens([descriptor(1)]))
        controller.cancel()
        #expect(controller.isPresented == false)
    }
}

/// Window-pick mode's wiring, exercised without a Screen Recording grant.
@MainActor
@Suite("Window pick mode", .serialized)
struct WindowPickModeTests {
    @Test("Opening in window mode maps the offered windows onto the display")
    func presentsWindowMode() {
        let controller = SelectionOverlayController(screens: FakeScreens([descriptor(1)]))
        controller.present(
            freezes: [frozen(1)],
            mode: .window,
            windows: [PickableWindowDescriptor(
                id: 42,
                title: "Test",
                applicationName: "Tester",
                bundleIdentifier: "com.bohdanbodnarenko.kadr.tests",
                globalFrame: DisplayRect(x: 10, y: 10, width: 100, height: 100)
            )]
        ) { _ in }

        #expect(controller.isPresented)
        controller.cancel()
        #expect(controller.isPresented == false)
    }

    @Test("Windows are mapped onto every display that shows them")
    func mapsAcrossDisplays() {
        let left = DisplayGeometry(
            displayID: 1,
            frame: DisplayRect(x: 0, y: 0, width: 1000, height: 800),
            scale: .retina
        )
        let right = DisplayGeometry(
            displayID: 2,
            frame: DisplayRect(x: 1000, y: 0, width: 1000, height: 800),
            scale: .oneToOne
        )
        let onLeft = PickableWindowDescriptor(
            id: 1,
            title: nil,
            applicationName: "A",
            bundleIdentifier: "a",
            globalFrame: DisplayRect(x: 100, y: 100, width: 200, height: 200)
        )
        let straddling = PickableWindowDescriptor(
            id: 2,
            title: nil,
            applicationName: "B",
            bundleIdentifier: "b",
            globalFrame: DisplayRect(x: 900, y: 100, width: 400, height: 200)
        )

        let mapped = SelectionOverlayController.mapWindows([onLeft, straddling], onto: [left, right])

        #expect(mapped[1]?.map(\PickableWindow.id) == [1, 2], "both windows appear on the left display")
        #expect(mapped[2]?.map(\PickableWindow.id) == [2], "only the straddling window reaches the right display")
        #expect(mapped[2]?.first?.frame.minX == -100, "its highlight starts off the left edge")
    }
}
