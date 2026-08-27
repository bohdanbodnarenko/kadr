import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

@Suite("Beautify layout")
struct BeautifyLayoutTests {
    @Test("Padding grows the canvas equally on every side")
    func paddingOnly() {
        let spec = BeautifySpec(
            padding: 40,
            cornerRadius: 0,
            shadow: .none,
            aspect: .original,
            autoBalance: true
        )
        let layout = BeautifyLayout.compute(contentSize: CGSize(width: 200, height: 100), spec: spec)

        #expect(layout.canvasSize == CGSize(width: 280, height: 180))
        #expect(layout.contentRect == CGRect(x: 40, y: 40, width: 200, height: 100))
    }

    @Test("A shadow that sticks out past the padding expands the canvas so it is not clipped")
    func shadowOutset() {
        let spec = BeautifySpec(
            padding: 10,
            cornerRadius: 0,
            shadow: BeautifyShadow(opacity: 0.3, blur: 20, offsetY: 8),
            aspect: .original,
            autoBalance: true
        )
        let layout = BeautifyLayout.compute(contentSize: CGSize(width: 100, height: 100), spec: spec)
        let expectedInset: CGFloat = 20 + 8

        #expect(layout.canvasSize.width == 100 + expectedInset * 2)
        #expect(layout.contentRect.origin.x == expectedInset)
    }

    @Test("A 1:1 preset never shrinks the capture", arguments: [
        CGSize(width: 200, height: 100),
        CGSize(width: 100, height: 200),
        CGSize(width: 150, height: 150)
    ])
    func squareDoesNotShrink(content: CGSize) {
        let spec = BeautifySpec(padding: 0, shadow: .none, aspect: .square, autoBalance: true)
        let layout = BeautifyLayout.compute(contentSize: content, spec: spec)

        #expect(layout.canvasSize.width == layout.canvasSize.height)
        #expect(layout.canvasSize.width >= content.width)
        #expect(layout.canvasSize.height >= content.height)
        #expect(layout.contentRect.size == content)
    }

    @Test("Auto-balance centres leftover space; off parks extra space under the capture")
    func autoBalanceVersusTopAlign() {
        let content = CGSize(width: 200, height: 100)
        let balanced = BeautifySpec(padding: 0, shadow: .none, aspect: .square, autoBalance: true)
        let parked = BeautifySpec(padding: 0, shadow: .none, aspect: .square, autoBalance: false)

        let centred = BeautifyLayout.compute(contentSize: content, spec: balanced)
        let top = BeautifyLayout.compute(contentSize: content, spec: parked)

        #expect(centred.contentRect.origin == CGPoint(x: 0, y: 50))
        #expect(top.contentRect.origin == CGPoint(x: 0, y: 0))
        #expect(centred.canvasSize == top.canvasSize)
    }

    @Test("Social presets produce the advertised aspect", arguments: [
        (BeautifySpec.twitter, CGFloat(16) / 9),
        (BeautifySpec.instagram, CGFloat(4) / 5),
        (BeautifySpec.story, CGFloat(9) / 16)
    ])
    func socialAspect(spec: BeautifySpec, ratio: CGFloat) {
        let layout = BeautifyLayout.compute(contentSize: CGSize(width: 800, height: 500), spec: spec)
        let actual = layout.canvasSize.width / layout.canvasSize.height
        #expect(abs(actual - ratio) < 0.001)
    }
}
