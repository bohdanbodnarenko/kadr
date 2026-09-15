import Foundation

/// A second-order damped spring (docs/16 STU-B1).
///
/// Tension 200 / friction 40 / inertia 2.25 is ζ ≈ 0.94. ω is derived from the move
/// duration so the inspector slider actually changes the move: ω ≈ 4 / Ts.
public struct DampedSpring: Sendable, Equatable {
    public var position: Double
    public var velocity: Double
    public var omega: Double
    public var zeta: Double

    public init(position: Double = 0, velocity: Double = 0, omega: Double = 8, zeta: Double = 0.94) {
        self.position = position
        self.velocity = velocity
        self.omega = max(omega, 0.01)
        self.zeta = min(max(zeta, 0.05), 2)
    }

    /// ω from a move duration, so settling lands near Ts.
    public static func omega(settlingIn duration: TimeInterval) -> Double {
        6 / max(duration, 0.05)
    }

    public mutating func advance(towards target: Double, by dt: TimeInterval) {
        let step = max(dt, 0)
        guard step > 0 else { return }
        let omega2 = omega * omega
        let acceleration = -2 * zeta * omega * velocity - omega2 * (position - target)
        velocity += acceleration * step
        position += velocity * step
    }

    public static func weights(sampleCount: Int) -> [Double] {
        let count = max(sampleCount, 1)
        let weight = 1 / Double(count)
        return Array(repeating: weight, count: count)
    }
}
