import Foundation
import Testing
@testable import AnnotationModel

@Suite("Default capture look")
struct DefaultCaptureLookTests {
    @Test("A saved look round-trips and is sanitized")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-default-look-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent(DefaultCaptureLook.fileName)
        let preset = StylePreset(name: "Test", beautify: .twitter)
        try JSONEncoder().encode(preset).write(to: url)
        let loaded = try JSONDecoder().decode(StylePreset.self, from: Data(contentsOf: url)).sanitized()
        #expect(loaded.name == "Test")
        #expect(loaded.beautify != nil)
    }
}
