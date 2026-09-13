import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// One of every command, so codability and identity are covered exhaustively.
private let everyCommand: [AnnotationCommand] = [
    .arrow(ArrowSpec(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 80))),
    .arrow(ArrowSpec(
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 100, y: 0),
        controlPoint: CGPoint(x: 50, y: -40),
        head: .concave
    )),
    .shape(ShapeSpec(kind: .rectangle, rect: CGRect(x: 5, y: 5, width: 50, height: 40))),
    .shape(ShapeSpec(
        kind: .roundedRectangle(cornerRadius: 8),
        rect: CGRect(x: 0, y: 0, width: 30, height: 30),
        fill: FillStyle(color: .white)
    )),
    .shape(ShapeSpec(kind: .ellipse, rect: CGRect(x: 0, y: 0, width: 60, height: 30))),
    .line(LineSpec(start: CGPoint(x: 1, y: 2), end: CGPoint(x: 3, y: 4))),
    .freehand(FreehandSpec(points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 0)])),
    .highlighter(HighlighterSpec(points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0)])),
    .text(TextSpec(string: "Hello", rect: CGRect(x: 10, y: 10, width: 120, height: 40))),
    .redaction(RedactionSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20))),
    .redaction(RedactionSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20), style: .defaultPixelate)),
    .spotlight(SpotlightSpec(rect: CGRect(x: 10, y: 10, width: 80, height: 60))),
    .counter(CounterSpec(number: 3, center: CGPoint(x: 50, y: 50))),
    .crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 100, height: 100), canExpandCanvas: true)),
    .beautify(BeautifySpec(padding: .points(24), aspect: .sixteenNine)),
    .camera(AnnotationCameraSpec(tiltDegrees: 18, orbitDegrees: -12, fieldOfViewDegrees: 40)),
    .progressiveBlur(ProgressiveBlurSpec(shape: .directional, extent: .scene, angleDegrees: 45)),
    .watermark(WatermarkSpec.tiled("Confidential")),
    .measure(MeasureSpec(start: CGPoint(x: 0, y: 40), end: CGPoint(x: 120, y: 40))),
    .measure(MeasureSpec(start: .zero, end: CGPoint(x: 80, y: 60), measuresBox: true)),
    .subjectLift(SubjectLiftSpec(maskPNG: Data([0x89, 0x50, 0x4E, 0x47]))),
    .subjectLift(SubjectLiftSpec(maskPNG: Data([0x01]), background: .color(.white))),
    .image(ImageSpec(pngData: Data([0x89, 0x50]), rect: CGRect(x: 4, y: 4, width: 60, height: 40)))
]

@Suite("Annotation commands")
struct AnnotationCommandTests {
    @Test("Every command round-trips through JSON unchanged", arguments: everyCommand)
    func codableRoundTrip(command: AnnotationCommand) throws {
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(AnnotationCommand.self, from: data)
        #expect(decoded == command)
        #expect(decoded.id == command.id)
    }

    @Test("A whole command list round-trips in order")
    func listRoundTrip() throws {
        let data = try JSONEncoder().encode(everyCommand)
        let decoded = try JSONDecoder().decode([AnnotationCommand].self, from: data)
        #expect(decoded == everyCommand)
    }

    @Test("Every command reports the tool that made it", arguments: everyCommand)
    func toolMapping(command: AnnotationCommand) {
        #expect(AnnotationTool.allCases.contains(command.tool))
    }

    @Test("Every tool has a command that produces it")
    func everyToolIsReachable() {
        let tools = Set(everyCommand.map(\.tool))
        #expect(tools == Set(AnnotationTool.allCases))
    }

    @Test("Crop and beautify are the annotations the user cannot select")
    func selectability() {
        for command in everyCommand {
            #expect(command.isSelectable == !command.tool.isCanvasChrome)
        }
    }

    @Test("Identities are unique per annotation")
    func uniqueIdentities() {
        let ids = everyCommand.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Colours clamp out-of-range components rather than storing nonsense")
    func colourClamping() {
        let colour = AnnotationColor(red: 5, green: -1, blue: 0.5, alpha: 12)
        #expect(colour.red == 1)
        #expect(colour.green == 0)
        #expect(colour.blue == 0.5)
        #expect(colour.alpha == 1)
    }

    @Test("Luminance separates light from dark, for contrasting text")
    func luminance() {
        #expect(AnnotationColor.white.luminance > 0.9)
        #expect(AnnotationColor.black.luminance < 0.1)
    }

    @Test("Negative stroke widths and font sizes are refused")
    func refusesNegativeSizes() {
        #expect(StrokeStyle(width: -4).width == 0)
        #expect(TextStyle(fontSize: -10).fontSize == 1)
        #expect(CounterSpec(center: .zero, radius: -5).radius == 1)
    }

    @Test("There are three arrow heads and seven text presets, as docs/03 §3 says")
    func specCounts() {
        #expect(ArrowHead.allCases.count == 3)
        #expect(TextStyle.presets.count == 7)
        #expect(StrokeStyle.widthPresets.allSatisfy { StrokeStyle.widthRange.contains($0) })
    }

    @Test("Redaction strength uses Screendrop's density mapping")
    func redactionDensity() {
        let blur = RedactionStyle.blur(density: 0.55)
        let pixelate = RedactionStyle.pixelate(density: 0.55)
        #expect(abs(blur.density - 0.55) < 0.001)
        #expect(abs(pixelate.density - 0.55) < 0.001)
        if case let .blur(radius) = blur {
            #expect(abs(radius - 17.4) < 0.001)
        }
        #expect(blur.togglingKind(pixelate: true).isPixelate)
        #expect(!pixelate.togglingKind(pixelate: false).isPixelate)
        #expect(abs(blur.withDensity(1).density - 1) < 0.001)
    }

    @Test("Spotlight dim and corner radius clamp to the documented ranges")
    func spotlightClamps() {
        let spec = SpotlightSpec(rect: CGRect(x: 0, y: 0, width: 40, height: 20), dimOpacity: 2, cornerRadius: 100)
        #expect(spec.dimOpacity == SpotlightSpec.dimOpacityRange.upperBound)
        #expect(spec.cornerRadius == SpotlightSpec.cornerRadiusRange.upperBound)
        #expect(spec.fittedCornerRadius == 10)
        #expect(SpotlightSpec(rect: .zero, dimOpacity: -1).dimOpacity == SpotlightSpec.dimOpacityRange.lowerBound)
    }

    @Test("Recolouring a filled shape keeps the fill's opacity")
    func recolorPreservesFillAlpha() {
        let filled = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(x: 0, y: 0, width: 20, height: 20),
            fill: FillStyle(color: .annotationRed.withAlpha(0.6))
        ))
        guard case let .shape(spec) = filled.applying(color: .black) else {
            Issue.record("expected a shape")
            return
        }
        #expect(spec.stroke.color == .black)
        #expect(abs((spec.fill.color?.alpha ?? 0) - 0.6) < 0.001)
    }

    @Test("Fill opacity rewrites only the fill alpha")
    func applyingFillOpacity() {
        let filled = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(x: 0, y: 0, width: 20, height: 20),
            fill: FillStyle(color: .annotationRed.withAlpha(0.25))
        ))
        guard case let .shape(spec) = filled.applying(fillOpacity: 0.8) else {
            Issue.record("expected a shape")
            return
        }
        #expect(abs((spec.fill.color?.alpha ?? 0) - 0.8) < 0.001)
        #expect(spec.fill.color?.red == AnnotationColor.annotationRed.red)
    }
}
