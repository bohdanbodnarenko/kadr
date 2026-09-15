import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// Beautify settings that survive being written down (docs/08 §2.6, docs/09 U1.1).
///
/// The discipline docs/08 calls out: every persisted field decodes with a default, so a
/// document written by an older Kadr opens rather than throwing, and a field that has since
/// changed meaning migrates rather than lingering.
@Suite("Beautify persistence")
struct BeautifyPersistenceTests {
    private func roundTrip(_ spec: BeautifySpec) throws -> BeautifySpec {
        try JSONDecoder().decode(BeautifySpec.self, from: JSONEncoder().encode(spec))
    }

    @Test("A spec round-trips whole", arguments: [
        BeautifySpec.cleanWhite,
        BeautifySpec.twitter,
        BeautifySpec.instagram,
        BeautifySpec.story,
        BeautifySpec.stuckBottom
    ])
    func specRoundTrips(spec: BeautifySpec) throws {
        #expect(try roundTrip(spec) == spec)
    }

    @Test("A wallpaper backdrop keeps its path")
    func imageBackdropRoundTrips() throws {
        let spec = BeautifySpec(backdrop: .image(path: "/tmp/wall.png"))
        guard case let .image(path) = try roundTrip(spec).backdrop else {
            Issue.record("the backdrop changed kind")
            return
        }
        #expect(path == "/tmp/wall.png")
    }

    @Test("A none backdrop round-trips")
    func noneBackdropRoundTrips() throws {
        let spec = BeautifySpec(backdrop: .none, border: .mount)
        guard case .none = try roundTrip(spec).backdrop else {
            Issue.record("the backdrop changed kind")
            return
        }
    }

    // MARK: - Documents from before U1.1

    /// The shape a pre-U1.1 Kadr wrote: bare point values, a two-stop gradient, and an
    /// `autoBalance` flag where alignment now lives.
    private let legacy = """
    {
      "id": {"rawValue": "6E1F3A5C-0B4D-4A6E-9F2C-8D7E5A1B3C4D"},
      "padding": 48,
      "cornerRadius": 16,
      "backdrop": {
        "gradient": {
          "start": {"red": 1, "green": 0, "blue": 0, "alpha": 1},
          "end": {"red": 0, "green": 0, "blue": 1, "alpha": 1},
          "angleDegrees": 45
        }
      },
      "shadow": {"opacity": 0.3, "blur": 24, "offsetY": 12},
      "aspect": "sixteenNine",
      "autoBalance": true
    }
    """

    @Test("An older document opens, with its lengths intact")
    func legacyLengths() throws {
        let spec = try JSONDecoder().decode(BeautifySpec.self, from: Data(legacy.utf8))

        #expect(spec.padding == .points(48))
        #expect(spec.cornerRadius == .points(16))
        #expect(spec.shadow.blur == .points(24))
        #expect(spec.shadow.offsetY == .points(12))
        #expect(spec.aspect == .sixteenNine)
    }

    @Test("An older two-stop gradient becomes a ramp with no middle")
    func legacyGradient() throws {
        let spec = try JSONDecoder().decode(BeautifySpec.self, from: Data(legacy.utf8))
        guard case let .gradient(ramp) = spec.backdrop else {
            Issue.record("the backdrop changed kind")
            return
        }
        #expect(ramp.start.red == 1)
        #expect(ramp.end.blue == 1)
        #expect(ramp.middle == nil)
        #expect(ramp.angleDegrees == 45)
    }

    /// The migration that matters: an old document must look exactly as it did. Sticking
    /// would move the capture, so a document that predates it opens with it off.
    @Test("autoBalance becomes alignment, and nothing sticks")
    func legacyAlignment() throws {
        let balanced = try JSONDecoder().decode(BeautifySpec.self, from: Data(legacy.utf8))
        #expect(balanced.alignment == .center)
        #expect(!balanced.sticksToEdges)

        let parked = try JSONDecoder().decode(
            BeautifySpec.self,
            from: Data(legacy.replacingOccurrences(of: "\"autoBalance\": true", with: "\"autoBalance\": false").utf8)
        )
        #expect(parked.alignment == .top)
        #expect(!parked.sticksToEdges)
    }

    /// A pre-U1.1 document laid out through the new code must produce the layout it always
    /// did — the whole point of decoding it rather than defaulting it.
    @Test("An older document lays out exactly as it used to")
    func legacyLayoutIsUnchanged() throws {
        let spec = try JSONDecoder().decode(BeautifySpec.self, from: Data(legacy.utf8))
        let layout = BeautifyLayout.compute(contentSize: CGSize(width: 400, height: 300), spec: spec)

        // Padding 48 beats the shadow's 24 + 12 = 36, so the inset is 48 a side, and the
        // 16:9 aspect then adds the rest of the width around a centred card — which is
        // exactly what the pre-U1.1 formula produced.
        #expect(layout.cardRect.minY == 48)
        #expect(layout.canvasSize == CGSize(width: 396 * 16 / 9, height: 396))
        #expect(layout.cardRect.minX == (layout.canvasSize.width - 400) / 2)
        #expect(layout.corners.largest == 16)
        #expect(layout.stuckEdges == .none)
    }

    @Test("Kadr writes the new spelling, not the old one")
    func savedSpecDropsTheLegacyKey() throws {
        let data = try JSONEncoder().encode(BeautifySpec.stuckBottom)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("autoBalance"))
        #expect(json.contains("alignment"))
        #expect(json.contains("sticksToEdges"))
    }

    @Test("A spec missing every optional field still decodes")
    func emptyObject() throws {
        let spec = try JSONDecoder().decode(BeautifySpec.self, from: Data("{}".utf8))
        #expect(spec.aspect == .original)
        #expect(spec.alignment == .center)
        #expect(spec.padding == .relative(0.08))
    }
}
