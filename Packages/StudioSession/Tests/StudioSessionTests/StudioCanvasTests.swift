import CoreGraphics
import Foundation
import Testing
@testable import StudioSession

@Suite("Studio canvas")
struct StudioCanvasTests {
    private let card = CGSize(width: 1920, height: 1080)

    @Test("The identity canvas does not grow the frame")
    func identityIsANoOp() {
        let layout = StudioCanvas.identity.layout(cardSize: card)
        #expect(layout.canvasSize == card)
        #expect(layout.cardRect == CGRect(origin: .zero, size: card))
        #expect(layout.cornerRadius == 0)
        #expect(StudioCanvas.identity.isIdentity)
    }

    @Test("Padding shrinks the card and keeps the canvas aspect")
    func paddingCentresTheCard() {
        let canvas = StudioCanvas(paddingFraction: 0.1)
        let layout = canvas.layout(cardSize: card)
        #expect(layout.canvasSize == card)
        #expect(layout.cardRect.width < card.width)
        #expect(layout.cardRect.height < card.height)
        #expect(abs(layout.cardRect.midX - layout.canvasSize.width / 2) < 0.001)
        #expect(abs(layout.cardRect.midY - layout.canvasSize.height / 2) < 0.001)
        let ratio = layout.cardRect.width / layout.cardRect.height
        #expect(abs(ratio - card.width / card.height) < 0.001)
    }

    @Test("A shadow with no padding still insets the card so it is not clipped")
    func shadowReservesInset() {
        let canvas = StudioCanvas(shadow: 1)
        let layout = canvas.layout(cardSize: card)
        #expect(layout.canvasSize == card)
        #expect(layout.cardRect.minX > 0)
    }

    @Test("Presenter is a padded card, not the raw frame")
    func presenterIsNotIdentity() {
        #expect(!StudioCanvas.presenter.isIdentity)
        let layout = StudioCanvas.presenter.layout(canvasSize: card, contentAspect: card.width / card.height)
        #expect(layout.cornerRadius > 0)
        #expect(layout.cardRect.width < card.width)
    }

    @Test("A canvas round-trips")
    func roundTrips() throws {
        let canvas = StudioCanvas.presenter
        let data = try JSONEncoder().encode(canvas)
        #expect(try JSONDecoder().decode(StudioCanvas.self, from: data) == canvas)
    }

    @Test("An empty object is the identity canvas")
    func emptyObject() throws {
        let canvas = try JSONDecoder().decode(StudioCanvas.self, from: Data("{}".utf8))
        #expect(canvas == .identity)
    }

    @Test("Picking a colour on a full-bleed frame opens the card so the fill shows")
    func colourRevealsTheCard() {
        var canvas = StudioCanvas.identity
        canvas.setBackdropKind(.colour)
        #expect(canvas.background == .solid(.graphite))
        #expect(canvas.paddingFraction == StudioCanvas.presenter.paddingFraction)
        #expect(canvas.cornerRadiusFraction == StudioCanvas.presenter.cornerRadiusFraction)
    }

    @Test("Picking wallpaper on a full-bleed frame opens the card")
    func wallpaperRevealsTheCard() {
        var canvas = StudioCanvas.identity
        canvas.setBackdropKind(.wallpaper)
        #expect(canvas.background == .wallpaper)
        #expect(canvas.paddingFraction == StudioCanvas.presenter.paddingFraction)
    }

    @Test("Picking a colour on an already padded card keeps the inset")
    func colourKeepsExistingPadding() {
        var canvas = StudioCanvas(paddingFraction: 0.1, background: .none)
        canvas.setSolid(StudioColor(red: 1, green: 0, blue: 0))
        #expect(canvas.paddingFraction == 0.1)
        #expect(canvas.background == .solid(StudioColor(red: 1, green: 0, blue: 0)))
    }

    @Test("Clearing the fill leaves the card size alone")
    func noneKeepsPadding() {
        var canvas = StudioCanvas.presenter
        canvas.setBackdropKind(.none)
        #expect(canvas.background == .none)
        #expect(canvas.paddingFraction == StudioCanvas.presenter.paddingFraction)
    }

    @Test("A two-colour gradient from an older session still opens")
    func legacyGradientDecodes() throws {
        let json = Data("""
        {"background":{"gradient":{"_0":{"red":0.1,"green":0.2,"blue":0.3},"_1":{"red":0.4,"green":0.5,"blue":0.6}}}}
        """.utf8)
        let canvas = try JSONDecoder().decode(StudioCanvas.self, from: json)
        guard case let .gradient(ramp) = canvas.background else {
            Issue.record("expected a gradient")
            return
        }
        #expect(ramp.stops.count == 2)
        #expect(abs(ramp.start.red - 0.1) < 0.001)
        #expect(abs(ramp.end.blue - 0.6) < 0.001)
        #expect(abs(ramp.angleDegrees - 90) < 0.001)
    }

    @Test("A multi-stop angled gradient round-trips")
    func multiStopGradientRoundTrips() throws {
        var canvas = StudioCanvas.presenter
        canvas.setGradient(StudioGradient(
            stops: [
                StudioColor(red: 1, green: 0, blue: 0),
                StudioColor(red: 0, green: 1, blue: 0),
                StudioColor(red: 0, green: 0, blue: 1)
            ],
            angleDegrees: 45
        ))
        let data = try JSONEncoder().encode(canvas)
        let decoded = try JSONDecoder().decode(StudioCanvas.self, from: data)
        #expect(decoded.background == canvas.background)
    }
}
