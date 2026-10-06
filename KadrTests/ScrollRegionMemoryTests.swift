import CoreGraphics
import Foundation
import Testing
@testable import Kadr

/// The frame a scrolling capture starts from, remembered between launches (docs/03 §1.6).
@Suite("Scroll region memory")
struct ScrollRegionMemoryTests {
    /// A store of its own per test, removed afterwards: a test that leaves a preferences
    /// file behind on the developer's Mac is a test that litters.
    private func withStore(_ body: (UserDefaults) -> Void) {
        let name = "com.bohdanbodnarenko.kadr.tests.scroll.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("no defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }
        body(defaults)
    }

    private let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)

    @Test("A frame comes back the size it was left")
    func remembersPerDisplay() {
        withStore { defaults in
            let frame = CGRect(x: 120, y: 200, width: 700, height: 500)
            ScrollRegionMemory.remember(frame, forDisplay: 1, defaults: defaults)

            #expect(ScrollRegionMemory.rect(forDisplay: 1, visible: visible, defaults: defaults) == frame)
            // Per display: the frame that fits a page on a laptop is not the one that fits
            // it on a 32-inch monitor.
            #expect(ScrollRegionMemory.rect(forDisplay: 2, visible: visible, defaults: defaults) == nil)
        }
    }

    @Test("Nothing remembered means no answer, and no crash")
    func emptyStore() {
        withStore { defaults in
            #expect(ScrollRegionMemory.rect(forDisplay: 7, visible: visible, defaults: defaults) == nil)
        }
    }

    @Test("A frame that no longer fits the screen is dropped")
    func dropsFramesThatNoLongerFit() {
        withStore { defaults in
            // Sized on a monitor that has since been unplugged.
            ScrollRegionMemory.remember(
                CGRect(x: 1800, y: 200, width: 900, height: 700),
                forDisplay: 3,
                defaults: defaults
            )

            #expect(ScrollRegionMemory.rect(forDisplay: 3, visible: visible, defaults: defaults) == nil)
        }
    }

    @Test("The newest frame wins")
    func overwrites() {
        withStore { defaults in
            let first = CGRect(x: 10, y: 40, width: 300, height: 300)
            ScrollRegionMemory.remember(first, forDisplay: 1, defaults: defaults)
            let second = CGRect(x: 20, y: 50, width: 400, height: 400)
            ScrollRegionMemory.remember(second, forDisplay: 1, defaults: defaults)

            #expect(ScrollRegionMemory.rect(forDisplay: 1, visible: visible, defaults: defaults) == second)
        }
    }
}
