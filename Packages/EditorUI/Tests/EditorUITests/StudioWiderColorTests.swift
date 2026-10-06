import Foundation
import StudioRender
import Testing
@testable import EditorUI

/// The Display P3 export choice (docs/18 Phase 4).
@Suite("Studio wider color")
struct StudioWiderColorTests {
    @Test("Wider color asks the renderer for P3, except for a GIF", arguments: [
        (StudioExportSettings.Container.mov, true, StudioColorSpace.displayP3),
        (.mp4, true, .displayP3),
        (.mov, false, .sRGB),
        (.gif, true, .sRGB)
    ])
    func colorSpace(container: StudioExportSettings.Container, wider: Bool, expected: StudioColorSpace) {
        var settings = StudioExportSettings(container: container)
        settings.widerColor = wider
        #expect(settings.rendererOptions.colorSpace == expected)
    }

    @Test("The choice is remembered, and older saved settings decode as sRGB")
    func coding() throws {
        var settings = StudioExportSettings()
        settings.widerColor = true
        let decoded = try JSONDecoder().decode(StudioExportSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.widerColor)

        // What a build from before the key wrote: the same settings, without it.
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        object.removeValue(forKey: "widerColor")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try !JSONDecoder().decode(StudioExportSettings.self, from: legacy).widerColor)
    }
}
