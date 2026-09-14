import CoreGraphics
import Shared
import Testing
@testable import SelectionUI

private func window(
    _ id: CGWindowID,
    app: String = "Safari",
    bundle: String = "com.apple.Safari",
    title: String? = nil,
    frame: CGRect
) -> PickableWindow {
    PickableWindow(id: id, title: title, applicationName: app, bundleIdentifier: bundle, frame: frame)
}

/// Front to back, with the front window overlapping the one behind it.
private let front = window(1, title: "Front", frame: CGRect(x: 100, y: 100, width: 300, height: 200))
private let behind = window(2, title: "Behind", frame: CGRect(x: 200, y: 150, width: 300, height: 200))
private let other = window(
    3,
    app: "Xcode",
    bundle: "com.apple.dt.Xcode",
    title: "Project",
    frame: CGRect(x: 600, y: 100, width: 200, height: 200)
)

@Suite("Picking a window")
struct WindowPickInteractionTests {
    private func interaction() -> WindowPickInteraction {
        WindowPickInteraction(windows: [front, behind, other])
    }

    @Test("The frontmost window under the pointer wins")
    func frontmostWins() {
        let pick = interaction()
        // A point inside both overlapping windows.
        #expect(pick.window(at: CGPoint(x: 250, y: 200))?.id == front.id)
        // A point only the back window covers.
        #expect(pick.window(at: CGPoint(x: 450, y: 300))?.id == behind.id)
    }

    @Test("A point over no window picks nothing")
    func emptySpace() {
        #expect(interaction().window(at: CGPoint(x: 10, y: 10)) == nil)
    }

    @Test("Hover only reports a change when the window actually changes")
    func hoverChangeIsDebounced() {
        var pick = interaction()
        let entered = pick.pointerMoved(to: CGPoint(x: 150, y: 150))
        #expect(entered)
        #expect(pick.hovered?.id == front.id)

        // Still inside the same window — no redraw needed.
        let stayed = pick.pointerMoved(to: CGPoint(x: 160, y: 160))
        #expect(stayed == false)

        let moved = pick.pointerMoved(to: CGPoint(x: 650, y: 150))
        #expect(moved)
        #expect(pick.hovered?.id == other.id)
    }

    @Test("Tab cycles between windows of the same app")
    func tabCyclesSameApp() {
        var pick = interaction()
        pick.pointerMoved(to: CGPoint(x: 150, y: 150))

        let next = pick.cycle()
        #expect(next?.id == behind.id)
        let wrapped = pick.cycle()
        #expect(wrapped?.id == front.id, "cycling wraps around")
    }

    @Test("Shift-Tab cycles the other way")
    func tabCyclesBackwards() {
        var pick = interaction()
        pick.pointerMoved(to: CGPoint(x: 150, y: 150))
        let previous = pick.cycle(reverse: true)
        #expect(previous?.id == behind.id)
    }

    @Test("With one window from an app, Tab falls back to every window")
    func tabFallsBackToAllWindows() {
        var pick = WindowPickInteraction(windows: [front, other])
        pick.pointerMoved(to: CGPoint(x: 650, y: 150))
        let next = pick.cycle()
        #expect(next?.id == front.id, "Tab must not appear dead for a single-window app")
    }

    @Test("Tab with nothing hovered starts at the frontmost window")
    func tabFromNothing() {
        var pick = interaction()
        let first = pick.cycle()
        #expect(first?.id == front.id)
    }

    @Test("Tab with no windows at all does nothing")
    func tabWithNoWindows() {
        var pick = WindowPickInteraction()
        let nothing = pick.cycle()
        #expect(nothing == nil)
    }

    @Test("A hovered window that disappears clears the highlight")
    func windowDisappears() {
        var pick = interaction()
        pick.pointerMoved(to: CGPoint(x: 150, y: 150))
        pick.setWindows([behind, other])

        #expect(pick.hovered == nil)
    }

    @Test("Auxiliary windows stay hidden until Command is held")
    func auxiliaryWindowsNeedCommand() {
        let auxiliary = PickableWindow(
            id: 4,
            title: "Panel",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            layer: 3,
            frame: CGRect(x: 120, y: 120, width: 80, height: 80)
        )
        var pick = WindowPickInteraction(windows: [front, auxiliary])
        #expect(pick.window(at: CGPoint(x: 150, y: 150))?.id == front.id)
        pick.setWindows([auxiliary])
        pick.includesAuxiliaryWindows = false
        #expect(pick.window(at: CGPoint(x: 150, y: 150)) == nil)
        pick.includesAuxiliaryWindows = true
        #expect(pick.window(at: CGPoint(x: 150, y: 150))?.id == auxiliary.id)
    }

    @Test("The title chip reads app and title, without repeating itself", arguments: [
        ("Safari", "Apple", "Safari — Apple"),
        ("Safari", nil, "Safari"),
        ("Safari", "Safari", "Safari"),
        ("Safari", "", "Safari")
    ])
    func label(app: String?, title: String?, expected: String) {
        let window = PickableWindow(
            id: 1,
            title: title,
            applicationName: app,
            bundleIdentifier: "com.apple.Safari",
            frame: .zero
        )
        #expect(window.label == expected)
    }

    @Test("A window with neither app nor title still says something")
    func labelFallback() {
        let window = PickableWindow(id: 42, title: nil, applicationName: nil, bundleIdentifier: nil, frame: .zero)
        #expect(window.label == "Window 42")
    }
}

@Suite("Mapping windows onto a display")
struct PickableWindowMappingTests {
    private let display = DisplayGeometry(
        displayID: 2,
        frame: DisplayRect(x: 1920, y: 0, width: 1000, height: 800),
        scale: .oneToOne
    )

    @Test("A window on this display is rebased to local coordinates")
    func mapsOntoDisplay() {
        let mapped = PickableWindowDescriptor(
            id: 1,
            title: "T",
            applicationName: "App",
            bundleIdentifier: "com.example",
            globalFrame: DisplayRect(x: 2020, y: 100, width: 300, height: 200)
        ).mapped(onto: display)
        #expect(mapped?.frame == CGRect(x: 100, y: 100, width: 300, height: 200))
    }

    @Test("A window on another display is not offered here")
    func skipsOtherDisplays() {
        let mapped = PickableWindowDescriptor(
            id: 1,
            title: nil,
            applicationName: nil,
            bundleIdentifier: nil,
            globalFrame: DisplayRect(x: 0, y: 0, width: 500, height: 500)
        ).mapped(onto: display)
        #expect(mapped == nil)
    }

    @Test("A window straddling two displays is offered on both, clipped to neither")
    func straddlingWindow() {
        let straddling = DisplayRect(x: 1820, y: 100, width: 300, height: 200)
        let mapped = PickableWindowDescriptor(
            id: 1,
            title: nil,
            applicationName: nil,
            bundleIdentifier: nil,
            globalFrame: straddling
        ).mapped(onto: display)
        // Negative x: the window starts off the left edge of this display, which is what
        // lets the highlight line up with the part the user can actually see.
        #expect(mapped?.frame == CGRect(x: -100, y: 100, width: 300, height: 200))
    }
}
