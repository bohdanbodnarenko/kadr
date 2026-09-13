import AnnotationModel
import Foundation
import Testing
@testable import EditorUI

@Suite("User colour palette")
struct EditorUserPaletteTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "app.kadr.tests.palette.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("A custom colour is saved and reloaded")
    func persistsAcrossLoad() {
        let defaults = isolatedDefaults()
        var palette = EditorUserPalette()
        let teal = AnnotationColor(red: 0.1, green: 0.7, blue: 0.7)
        let added = palette.add(teal)
        #expect(added)
        palette.save(to: defaults)

        let loaded = EditorUserPalette.load(from: defaults)
        #expect(loaded.colors.count == 1)
        #expect(loaded.contains(teal))
    }

    @Test("Built-in swatches are not duplicated into favourites")
    func skipsBuiltInSwatches() {
        var palette = EditorUserPalette()
        let added = palette.add(.annotationRed)
        #expect(!added)
        #expect(palette.colors.isEmpty)
    }

    @Test("The oldest favourite drops when the palette is full")
    func evictsOldestAtCapacity() {
        var palette = EditorUserPalette()
        for index in 0 ..< EditorUserPalette.capacity + 1 {
            let color = AnnotationColor(red: Double(index) / 20, green: 0.4, blue: 0.5)
            let added = palette.add(color)
            #expect(added)
        }
        #expect(palette.colors.count == EditorUserPalette.capacity)
        #expect(!palette.contains(AnnotationColor(red: 0, green: 0.4, blue: 0.5)))
    }

    @Test("Option-remove drops a favourite")
    func removeDropsColour() {
        var palette = EditorUserPalette()
        let teal = AnnotationColor(red: 0.1, green: 0.7, blue: 0.7)
        let added = palette.add(teal)
        #expect(added)
        palette.remove(teal)
        #expect(palette.colors.isEmpty)
    }
}
