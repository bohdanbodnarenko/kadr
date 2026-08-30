import Foundation
import Testing
@testable import AnnotationModel

@Suite("Style preset transfer")
struct StylePresetTransferTests {
    @Test("A look round-trips without a local wallpaper")
    func roundTrips() throws {
        let preset = StylePreset(name: "Hero", beautify: .twitter, camera: .lean)
        let data = try StylePresetTransfer(preset: preset).encoded()
        let decoded = try StylePresetTransfer.decoding(data)
        #expect(decoded.name == "Hero")
        #expect(decoded.beautify == .twitter)
        #expect(decoded.camera == .lean)
        #expect(data.count <= StylePresetTransfer.maximumByteCount)
    }

    @Test("A local wallpaper is replaced with a solid fill")
    func stripsImagePaths() throws {
        var beautify = BeautifySpec.twitter
        beautify.backdrop = .image(path: "/Users/me/Pictures/desk.png")
        let preset = StylePreset(name: "Mine", beautify: beautify)
        let decoded = try StylePresetTransfer.decoding(StylePresetTransfer(preset: preset).encoded())
        #expect(decoded.beautify?.backdrop == .solid(.black))
    }

    @Test("A file over the size cap is refused")
    func rejectsOversize() {
        let data = Data(repeating: 1, count: StylePresetTransfer.maximumByteCount + 1)
        #expect(throws: StylePresetTransfer.TransferError.tooLarge) {
            try StylePresetTransfer.decoding(data)
        }
    }
}
