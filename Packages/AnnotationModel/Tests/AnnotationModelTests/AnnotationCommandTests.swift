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
    .counter(CounterSpec(number: 3, center: CGPoint(x: 50, y: 50))),
    .crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 100, height: 100), canExpandCanvas: true))
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

    @Test("Crop is the only annotation the user cannot select")
    func selectability() {
        for command in everyCommand {
            #expect(command.isSelectable == (command.tool != .crop))
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

    @Test("There are three arrow heads and five text presets, as docs/03 §3 says")
    func specCounts() {
        #expect(ArrowHead.allCases.count == 3)
        #expect(TextStyle.presets.count == 5)
    }
}
