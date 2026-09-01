import AppKit
import Foundation
import Testing
@testable import OverlayKit

@MainActor
@Suite("Countdown placement")
struct CountdownPanelTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("A still-capture badge sits in the top-right")
    func cornerIsTopTrailing() {
        let size = CountdownPanel.size(for: .corner)
        let frame = CountdownPanel.frame(size: size, placement: .corner, in: screen)
        #expect(frame.maxX == screen.maxX - 24)
        #expect(frame.maxY == screen.maxY - 24)
        #expect(frame.size == CGSize(width: 96, height: 96))
    }

    @Test("A recording countdown sits in the middle of the screen")
    func centerIsCentered() {
        let size = CountdownPanel.size(for: .center)
        let frame = CountdownPanel.frame(size: size, placement: .center, in: screen)
        #expect(frame.midX == screen.midX)
        #expect(frame.midY == screen.midY)
        #expect(frame.size == CGSize(width: 160, height: 160))
    }
}
