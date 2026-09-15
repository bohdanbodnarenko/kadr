import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

@Suite("Style scale")
struct StyleScaleTests {
    @Test("A 1440 pt canvas is 1×", arguments: [
        CGSize(width: 1440, height: 900),
        CGSize(width: 900, height: 1440)
    ])
    func referenceIsIdentity(size: CGSize) {
        #expect(abs(StyleScale.factor(for: size) - 1) < 0.001)
    }

    @Test("Small captures do not shrink below 0.75")
    func clampsLow() {
        #expect(StyleScale.factor(for: CGSize(width: 100, height: 80)) == 0.75)
    }

    @Test("Huge captures do not grow past 3")
    func clampsHigh() {
        #expect(StyleScale.factor(for: CGSize(width: 10000, height: 8000)) == 3)
    }

    @Test("A 2880 pt canvas is 2×")
    func doubles() {
        #expect(abs(StyleScale.factor(for: CGSize(width: 2880, height: 1620)) - 2) < 0.001)
    }
}
