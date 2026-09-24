import AppKit
import CoreGraphics
import Foundation
import Shared
import StudioSession
import Testing
@testable import Kadr

/// A pointer event crossing from the OS into the sidecar (docs/11 C1, S0.1).
///
/// The seam three consecutive reviews have found a defect on, and the one nothing tested.
/// macOS has two global point spaces that are vertical mirrors of each other — `CGEvent`
/// reports display space with the origin top-left, `NSEvent.mouseLocation` reports screen
/// space with the origin bottom-left — and both are spelled `CGPoint`. The recorder fed
/// the first into a converter written for the second, the two flips cancelled into a
/// plausible number, and every sample in every sidecar came out mirrored.
///
/// Nothing caught it because the tests passed an identity converter: with no conversion
/// under test, the coordinate space of the input could not matter. So these drive the real
/// producer — the tap's own handler and the monitor's own handler — into the real
/// converter, and assert the pixel.
@MainActor
@Suite("Pointer seam")
struct PointerSeamTests {
    /// A 1000×800 display at the origin, at 2×. Deliberately not square: a mirror on a
    /// square display is invisible at the centre and a test that used one would pass.
    private let screen = ScreenRect(x: 0, y: 0, width: 1000, height: 800)
    private let scale = DisplayScale(2)

    private func recorder() -> PointerTelemetryRecorder {
        let recorder = PointerTelemetryRecorder()
        let screen = screen
        let scale = scale
        recorder.start(
            pointConverter: { screen.pixelPoint(for: $0, scale: scale) },
            // The fixture's own display arrangement: a 800-point-tall primary, which is
            // the axis the two global spaces reflect about.
            space: GlobalCoordinateSpace(primaryDisplayHeight: 800)
        )
        return recorder
    }

    // MARK: - The two spaces land in the same place

    /// The heart of it. A physical click at a given spot produces the same pixel whichever
    /// rung of the ladder observed it — which is what "a fallback" means, and what was
    /// false: the tap's answer was the vertical mirror of the monitor's.
    @Test(
        "Both rungs of the ladder agree about where a click was",
        arguments: [
            // (display-space y as CGEvent reports it, screen-space y as NSEvent does)
            // Never the exclusive edge: `ScreenRect.contains` is half-open, so a point at
            // exactly `maxY` belongs to whatever display is above this one.
            (1.0, 799.0), (100.0, 700.0), (400.0, 400.0), (799.0, 1.0)
        ]
    )
    func rungsAgree(displayY: CGFloat, screenY: CGFloat) throws {
        let viaTap = recorder()
        viaTap.advance(to: 1)
        viaTap.recordTapEventForTesting(type: .leftMouseDown, at: CGPoint(x: 300, y: displayY))
        let tapClick = try #require(viaTap.stop().clicks.first)

        let viaMonitor = recorder()
        viaMonitor.advance(to: 1)
        viaMonitor.recordMonitorEventForTesting(type: .leftMouseDown, at: CGPoint(x: 300, y: screenY))
        let monitorClick = try #require(viaMonitor.stop().clicks.first)

        #expect(abs(tapClick.position.x - monitorClick.position.x) < 0.001)
        #expect(
            abs(tapClick.position.y - monitorClick.position.y) < 0.001,
            "the tap put it at \(tapClick.position.y) and the monitor at \(monitorClick.position.y)"
        )
    }

    /// The absolute answer, not just agreement — two rungs could agree and both be wrong.
    /// A `CGEvent` at display y = 100 on an 800-point display at 2× is 200 pixels down.
    @Test("A tap event lands at the pixel it names")
    func tapLandsAtTheRightPixel() throws {
        let recorder = recorder()
        recorder.advance(to: 1)
        recorder.recordTapEventForTesting(type: .leftMouseDown, at: CGPoint(x: 250, y: 100))

        let click = try #require(recorder.stop().clicks.first)
        #expect(abs(click.position.x - 500) < 0.001)
        #expect(abs(click.position.y - 200) < 0.001, "y came out \(click.position.y); a mirror would give 1400")
    }

    /// The specific wrong answer, named. Asserting it is absent says what the regression
    /// looks like, which a test for the right answer alone does not.
    @Test("A tap event is not vertically mirrored")
    func tapIsNotMirrored() throws {
        let recorder = recorder()
        recorder.advance(to: 1)
        recorder.recordTapEventForTesting(type: .leftMouseDown, at: CGPoint(x: 250, y: 100))

        let click = try #require(recorder.stop().clicks.first)
        let mirrored = (screen.height - 100) * scale.factor
        #expect(abs(click.position.y - mirrored) > 1, "the sample is the mirror of where the click was")
    }

    // MARK: - Once per click

    /// Both rungs used to be installed and only *labelled*, so one press appended two
    /// events at the same instant — one right, one mirrored, two ripples in the export.
    @Test("One press records one click")
    func onePressOneClick() {
        let recorder = recorder()
        recorder.advance(to: 1)
        recorder.recordTapEventForTesting(type: .leftMouseDown, at: CGPoint(x: 250, y: 100))
        recorder.recordMonitorEventForTesting(type: .leftMouseDown, at: CGPoint(x: 250, y: 700))

        #expect(recorder.stop().clicks.count == 1, "one physical press was recorded twice")
    }

    /// The gate is a duplicate filter, not a rate limit: a real double-click is two presses
    /// milliseconds apart and both belong in the sidecar.
    @Test("A genuine double-click records two")
    func doubleClickRecordsTwo() {
        let recorder = recorder()
        recorder.advance(to: 1)
        recorder.recordTapEventForTesting(type: .leftMouseDown, at: CGPoint(x: 250, y: 100))
        recorder.advance(to: 1.2)
        recorder.recordTapEventForTesting(type: .leftMouseDown, at: CGPoint(x: 250, y: 100))

        #expect(recorder.stop().clicks.count == 2)
    }

    @Test("A press and its release are both recorded")
    func pressAndReleaseBothRecorded() {
        let recorder = recorder()
        recorder.advance(to: 1)
        recorder.recordTapEventForTesting(type: .leftMouseDown, at: CGPoint(x: 250, y: 100))
        recorder.recordTapEventForTesting(type: .leftMouseUp, at: CGPoint(x: 250, y: 100))

        let clicks = recorder.stop().clicks
        #expect(clicks.count == 2)
        #expect(clicks.first?.isDown == true)
        #expect(clicks.last?.isDown == false)
    }

    // MARK: - Displays that are not the primary

    /// A display arranged above the primary has negative y in display space. The point
    /// converts into screen space above the primary's top edge, which is outside the
    /// recorded rect — so it is dropped, deliberately and not silently by accident.
    @Test("A point on another display is dropped rather than recorded wrongly")
    func pointOffTheRecordedDisplayIsDropped() {
        let recorder = recorder()
        recorder.advance(to: 1)
        // 200 points above the primary's top edge.
        recorder.recordTapEventForTesting(type: .leftMouseDown, at: CGPoint(x: 250, y: -200))
        #expect(recorder.stop().clicks.isEmpty)
    }

    @Test("A point past the right edge is dropped")
    func pointPastTheEdgeIsDropped() {
        let recorder = recorder()
        recorder.advance(to: 1)
        recorder.recordTapEventForTesting(type: .leftMouseDown, at: CGPoint(x: 2000, y: 100))
        #expect(recorder.stop().clicks.isEmpty)
    }

    // MARK: - The conversion itself

    /// Table-driven over the arrangements a real Mac has, against the converter the
    /// recorder actually uses rather than a stand-in.
    @Test(
        "Screen points convert to the pixels under them",
        arguments: [
            // (screen rect, scale, screen point, expected pixel)
            // The top-left pixel: screen y just inside the top edge, which is row zero.
            (ScreenRect(x: 0, y: 0, width: 1000, height: 800), 2.0, CGPoint(x: 0, y: 799), CGPoint(x: 0, y: 2)),
            (ScreenRect(x: 0, y: 0, width: 1000, height: 800), 2.0, CGPoint(x: 500, y: 400), CGPoint(x: 1000, y: 800)),
            (ScreenRect(x: 0, y: 0, width: 1000, height: 800), 1.0, CGPoint(x: 250, y: 600), CGPoint(x: 250, y: 200)),
            // A display to the left of the primary: negative x in screen space.
            (
                ScreenRect(x: -1600, y: 0, width: 1600, height: 1000),
                2.0,
                CGPoint(x: -800, y: 500),
                CGPoint(x: 1600, y: 1000)
            )
        ]
    )
    func screenPointsConvert(rect: ScreenRect, factor: CGFloat, point: CGPoint, expected: CGPoint) throws {
        let pixel = try #require(
            rect.pixelPoint(for: ScreenPoint(x: point.x, y: point.y), scale: DisplayScale(factor))
        )
        #expect(abs(pixel.x - expected.x) < 0.001)
        #expect(abs(pixel.y - expected.y) < 0.001)
    }

    /// The conversion the tap needs, on its own: display space and screen space are
    /// reflections about the primary display's height.
    @Test("Display space and screen space are reflections of each other")
    func spacesAreReflections() {
        let space = GlobalCoordinateSpace(primaryDisplayHeight: 800)
        let display = DisplayPoint(x: 300, y: 100)
        let screen = display.inScreenSpace(space)

        #expect(screen.x == 300)
        #expect(screen.y == 700)
        // And back again, because a conversion that does not round-trip is a conversion
        // somebody will apply twice.
        let round = screen.inDisplaySpace(space)
        #expect(round.x == display.x)
        #expect(round.y == display.y)
    }

    // MARK: - Dropping a rung (docs/11 S0.2)

    /// macOS disables a tap whose callback runs long, and says so by delivering one of two
    /// event types through the callback it has just switched off. That notice used to be
    /// ignored: the tap went quiet, the ladder stayed on its top rung, and the sidecar
    /// simply stopped — which is the failure mode `TelemetryPolicy.tapSilenceTimeout` was
    /// written to describe and never used to check.
    @Test(
        "A tap macOS disables drops the recorder to the next rung",
        arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput]
    )
    func disabledTapDropsARung(reason: CGEventType) {
        let recorder = recorder()
        recorder.sourceForTesting = .eventTap
        // A timeout is revived up to three times a minute when a real tap exists — which
        // it does on a Mac that has granted Input Monitoring, and not on one that has not.
        // A fourth notice drops the rung either way, so the test no longer depends on the
        // grants of the machine running it (docs/17 T-REL-7).
        for _ in 0 ..< 4 {
            recorder.tapWentDead(reason: reason)
        }

        #expect(recorder.sourceForTesting != .eventTap, "the ladder stayed on a rung that is gone")
        _ = recorder.stop()
    }

    /// And it only drops once: a second notice for a tap already torn down must not tear
    /// down the monitors that replaced it.
    @Test("A second disable notice does not drop a second rung")
    func disablingTwiceDropsOnce() {
        let recorder = recorder()
        recorder.sourceForTesting = .eventTap
        recorder.tapWentDead(reason: .tapDisabledByTimeout)
        let after = recorder.sourceForTesting
        recorder.tapWentDead(reason: .tapDisabledByTimeout)

        #expect(recorder.sourceForTesting == after)
        _ = recorder.stop()
    }

    /// Silence alone proves nothing — the user may simply not be touching the mouse — so
    /// the probe must not drop a rung just because the clock advanced past the timeout.
    @Test("A quiet tap over a still pointer is left alone")
    func silenceWithoutMovementIsNotADeadTap() {
        let recorder = recorder()
        recorder.sourceForTesting = .eventTap
        // Two probes, both finding the pointer where it was.
        recorder.advance(to: TelemetryPolicy.tapSilenceTimeout + 1)
        recorder.advance(to: TelemetryPolicy.tapSilenceTimeout * 2 + 2)

        #expect(recorder.sourceForTesting == .eventTap, "a still pointer was mistaken for a dead tap")
        _ = recorder.stop()
    }
}
