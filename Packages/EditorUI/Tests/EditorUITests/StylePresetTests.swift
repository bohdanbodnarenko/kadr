import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// Whole looks, saved and recognised (docs/09 U1.5).
@MainActor
@Suite("Style presets")
struct StylePresetTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
    }

    private func throwawayStore() -> StylePresetStore {
        let suite = UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return StylePresetStore(store: defaults)
    }

    // MARK: - Applying

    /// One decision, one undo press. Four setters would leave three half-applied looks on
    /// the stack that nobody chose.
    @Test("Applying a whole look is a single undo step")
    func applyingIsOneStep() {
        let model = makeModel()
        let preset = StylePreset(
            name: "Everything",
            beautify: .twitter,
            camera: .lean,
            progressiveBlur: .focus,
            watermark: .tiled("Kadr")
        )
        model.applyStylePreset(preset)

        #expect(model.document.beautify != nil)
        #expect(model.document.camera != nil)
        #expect(model.document.progressiveBlur != nil)
        #expect(model.document.watermark != nil)

        model.undo()
        #expect(model.document.beautify == nil)
        #expect(model.document.camera == nil)
        #expect(model.document.progressiveBlur == nil)
        #expect(model.document.watermark == nil)
    }

    @Test("Applying a look replaces the one before it rather than stacking")
    func applyingReplaces() {
        let model = makeModel()
        model.applyStylePreset(StylePreset(name: "First", beautify: .twitter, camera: .hero))
        model.applyStylePreset(StylePreset(name: "Second", beautify: .story))

        #expect(model.document.camera == nil, "the second look has no camera, so neither should the document")
        let beautifyCount = model.document.commands.count { command in
            if case .beautify = command {
                return true
            }
            return false
        }
        #expect(beautifyCount == 1)
    }

    @Test("An empty preset clears the chrome")
    func emptyPresetClears() {
        let model = makeModel()
        model.applyStylePreset(StylePreset(name: "Full", beautify: .twitter, camera: .lean))
        model.applyStylePreset(StylePreset(name: "Nothing"))

        #expect(model.document.beautify == nil)
        #expect(model.document.camera == nil)
    }

    @Test("Clearing a look removes the chrome")
    func clearStylePresetRemovesChrome() {
        let model = makeModel()
        model.applyStylePreset(StylePreset(name: "Full", beautify: .twitter, camera: .lean))
        model.clearStylePreset()

        #expect(model.document.beautify == nil)
        #expect(model.document.camera == nil)
    }

    @Test("Annotations are untouched by a look")
    func annotationsSurvive() {
        let model = makeModel()
        model.document.add(.shape(ShapeSpec(rect: CGRect(x: 0, y: 0, width: 40, height: 40))))
        model.applyStylePreset(StylePreset(name: "Look", beautify: .twitter))

        #expect(model.document.commands.contains { command in
            if case .shape = command {
                return true
            }
            return false
        })
    }

    // MARK: - Recognising

    /// The "(edited)" state rests on this: a preset must match the document it was just
    /// applied to, even though applying it gave the commands new ids.
    @Test("A preset matches the document it was applied to")
    func matchesAfterApplying() {
        let model = makeModel()
        let preset = StylePreset(name: "Look", beautify: .twitter, camera: .lean)
        model.applyStylePreset(preset)

        #expect(preset.matches(model.document))
    }

    @Test("Changing anything stops the match")
    func editingBreaksTheMatch() {
        let model = makeModel()
        let preset = StylePreset(name: "Look", beautify: .twitter)
        model.applyStylePreset(preset)
        #expect(preset.matches(model.document))

        model.applyBeautify(BeautifySpec(padding: .relative(0.3)))
        #expect(!preset.matches(model.document))
    }

    @Test("A different name is still the same look")
    func nameIsNotPartOfTheLook() {
        let model = makeModel()
        model.applyStylePreset(StylePreset(name: "One", beautify: .story))
        #expect(StylePreset(name: "Another entirely", beautify: .story).matches(model.document))
    }

    @Test("The matching preset is found among a list")
    func findsTheMatch() {
        let model = makeModel()
        model.applyStylePreset(StylePreset(name: "Story", beautify: .story))

        let matched = model.document.matchingStylePreset(among: StylePreset.builtIn)
        #expect(matched?.name == "Story")
    }

    @Test("A bare document matches nothing")
    func bareDocumentMatchesNothing() {
        let model = makeModel()
        #expect(model.document.matchingStylePreset(among: StylePreset.builtIn) == nil)
        #expect(StylePreset(name: "", capturing: model.document).isEmpty)
    }

    // MARK: - Storage

    @Test("A saved preset comes back")
    func savingAndLoading() {
        let store = throwawayStore()
        store.add(StylePreset(name: "Mine", beautify: .twitter))

        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "Mine")
    }

    @Test("Saving over a name replaces it rather than duplicating")
    func savingOverAName() {
        let store = throwawayStore()
        store.add(StylePreset(name: "Mine", beautify: .twitter))
        store.add(StylePreset(name: "mine", beautify: .story))

        #expect(store.load().count == 1)
        #expect(store.load()[0].beautify?.aspect == .nineSixteen)
    }

    @Test("Deleting removes just that one")
    func deleting() {
        let store = throwawayStore()
        store.add(StylePreset(name: "One", beautify: .twitter))
        let second = StylePreset(name: "Two", beautify: .story)
        store.add(second)

        store.remove(id: second.id)
        #expect(store.load().map(\.name) == ["One"])
    }

    @Test("Built-ins come first in the list the inspector shows")
    func builtInsComeFirst() {
        let store = throwawayStore()
        store.add(StylePreset(name: "Mine", beautify: .twitter))

        let all = store.all()
        #expect(all.count == StylePreset.builtIn.count + 1)
        #expect(all.last?.name == "Mine")
    }

    /// Presets are the only thing in the editor a user authors and cannot recreate from
    /// the capture, so a corrupted primary must not lose them.
    @Test("A corrupted list is recovered from the copy")
    func recoveryCopy() {
        let suite = UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not open a defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        let store = StylePresetStore(store: defaults)

        store.add(StylePreset(name: "First", beautify: .twitter))
        // A second save moves the first list into the recovery slot.
        store.add(StylePreset(name: "Second", beautify: .story))
        defaults.set(Data("not json".utf8), forKey: "editor.style.presets")

        let recovered = store.load()
        #expect(recovered.map(\.name) == ["First"], "the older complete list should survive")
        #expect(store.load().map(\.name) == ["First"], "and be written back")
    }

    @Test("Nothing stored means no presets, not a crash")
    func emptyStore() {
        #expect(throwawayStore().load().isEmpty)
    }

    // MARK: - Persistence discipline

    @Test("A preset round-trips whole")
    func roundTrips() throws {
        let preset = StylePreset(
            name: "Everything",
            beautify: .instagram,
            camera: .hero,
            progressiveBlur: .fade,
            watermark: .tiled("Kadr")
        )
        let data = try JSONEncoder().encode(preset)
        #expect(try JSONDecoder().decode(StylePreset.self, from: data) == preset)
    }

    /// A preset saved by a later Kadr with a fifth effect in it arrives without that
    /// effect rather than failing to arrive.
    @Test("An unknown field is ignored, not fatal")
    func unknownFieldsAreIgnored() throws {
        let json = """
        {"name": "Future", "version": 1, "sparkle": {"amount": 11}}
        """
        let preset = try JSONDecoder().decode(StylePreset.self, from: Data(json.utf8))
        #expect(preset.name == "Future")
        #expect(preset.isEmpty)
    }

    @Test("An unsupported version is refused")
    func unsupportedVersionIsRefused() {
        let json = """
        {"name": "Future", "version": 9}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StylePreset.self, from: Data(json.utf8))
        }
    }

    @Test("A preset with nothing in it at all still decodes")
    func emptyObject() throws {
        let preset = try JSONDecoder().decode(StylePreset.self, from: Data("{}".utf8))
        #expect(preset.name == "Untitled")
        #expect(preset.version == 1)
    }

    @Test("Every built-in look is distinct")
    func builtInsAreDistinct() {
        let appearances = Set(StylePreset.builtIn.map(\.appearance))
        #expect(appearances.count == StylePreset.builtIn.count)
    }
}
