import SwiftUI
import Testing
@testable import ControlKit

/// The shared design tokens (docs/18 X-1, X-3).
@Suite("Design tokens")
struct KadrTokensTests {
    @Test("Increase Contrast raises every fill", arguments: KadrFill.Role.allCases)
    func contrastRaises(role: KadrFill.Role) {
        #expect(KadrFill.opacity(role, increaseContrast: true) > KadrFill.opacity(role, increaseContrast: false))
    }

    @Test("Fills stay visible but never opaque", arguments: KadrFill.Role.allCases, [false, true])
    func fillRange(role: KadrFill.Role, increaseContrast: Bool) {
        let value = KadrFill.opacity(role, increaseContrast: increaseContrast)
        #expect(value > 0 && value < 1)
    }

    @Test("The ramp ascends from micro, which is at least 10 pt")
    func ramp() {
        let ramp = [KadrType.micro, KadrType.caption, KadrType.body, KadrType.title]
        #expect(ramp == ramp.sorted())
        #expect(KadrType.micro >= 10)
    }

    @Test("Radii and spacing ascend", arguments: [
        [KadrRadius.small, KadrRadius.medium, KadrRadius.large, KadrRadius.panel],
        [KadrSpace.xxs, KadrSpace.xs, KadrSpace.small, KadrSpace.medium, KadrSpace.large, KadrSpace.xl]
    ])
    func ascending(scale: [CGFloat]) {
        #expect(scale == scale.sorted())
        #expect(Set(scale).count == scale.count)
    }
}
