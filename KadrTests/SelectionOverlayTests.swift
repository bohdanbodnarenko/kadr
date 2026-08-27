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
        var result: SelectionResult?

        controller.present(freezes: [frozen(1)]) { selection in
            completions += 1
            result = selection
        }
        #expect(controller.isPresented)

        controller.cancel()

        #expect(controller.isPresented == false)
        #expect(completions == 1)
        #expect(result == nil, "cancelling must not produce a selection")
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
