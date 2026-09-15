import Foundation
import Testing
@testable import StudioRender

@Suite("Damped spring")
struct DampedSpringTests {
    @Test("No velocity jump at rest")
    func restHasNoKick() {
        var spring = DampedSpring(position: 1, velocity: 0, omega: 8)
        spring.advance(towards: 1, by: 1.0 / 120)
        #expect(abs(spring.velocity) < 0.0001)
        #expect(abs(spring.position - 1) < 0.0001)
    }

    @Test("Settles within 15% of the asked duration")
    func settlingTime() {
        let duration: TimeInterval = 0.6
        var spring = DampedSpring(position: 0, omega: DampedSpring.omega(settlingIn: duration))
        var elapsed: TimeInterval = 0
        let step = 1.0 / 120
        while elapsed < duration * 2, abs(spring.position - 1) > 0.02 {
            spring.advance(towards: 1, by: step)
            elapsed += step
        }
        #expect(elapsed <= duration * 1.15)
        #expect(elapsed >= duration * 0.5)
    }

    @Test("Motion-blur weights are equal")
    func equalWeights() {
        #expect(DampedSpring.weights(sampleCount: 4) == [0.25, 0.25, 0.25, 0.25])
        #expect(DampedSpring.weights(sampleCount: 1) == [1])
    }
}
