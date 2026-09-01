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
}
