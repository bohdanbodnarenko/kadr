import AppKit
import Foundation
import Testing
@testable import Kadr

@MainActor
@Suite("Capture countdown")
struct CaptureCountdownTests {
    @Test("A running countdown reports the seconds still showing")
    func remainingSecondsTickImmediately() async {
        let countdown = CaptureCountdown()
        var ticks: [Int] = []
        countdown.onTick = { ticks.append($0) }
        countdown.run(seconds: 3) {}
        try? await Task.sleep(for: .milliseconds(80))
        #expect(countdown.isRunning)
        #expect(countdown.remainingSeconds == 3)
        #expect(ticks == [3])
        countdown.cancel()
        #expect(!countdown.isRunning)
        #expect(countdown.remainingSeconds == 0)
    }

    @Test("Zero seconds skips the wait")
    func zeroSecondsFiresImmediately() {
        let countdown = CaptureCountdown()
        var fired = false
        countdown.run(seconds: 0) { fired = true }
        #expect(fired)
        #expect(!countdown.isRunning)
        #expect(countdown.remainingSeconds == 0)
    }

    @Test("An explicit screen wins over every other hint")
    func resolveScreenPrefersExplicitScreen() {
        let screen = NSScreen.screens.first
        #expect(CaptureCountdown.resolveScreen(screen: screen, displayID: 99999) == screen)
    }

    @Test("A display ID beats the pointer when no screen is passed")
    func resolveScreenUsesDisplayID() {
        guard let screen = NSScreen.screens.first else { return }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard displayID != 0 else { return }
        #expect(CaptureCountdown.resolveScreen(screen: nil, displayID: displayID) == screen)
    }

    @Test("Cancel clears a running countdown")
    func cancelStopsRunningCountdown() {
        let countdown = CaptureCountdown()
        countdown.run(seconds: 5) {}
        #expect(countdown.isRunning)
        countdown.cancel()
        #expect(!countdown.isRunning)
        #expect(countdown.remainingSeconds == 0)
    }
}
