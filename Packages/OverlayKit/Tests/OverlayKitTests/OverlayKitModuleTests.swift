import Testing
@testable import OverlayKit

@Suite("OverlayKit module")
struct OverlayKitModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(OverlayKitModule.identifier == "OverlayKit")
        #expect(OverlayKitModule.layer == 1)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in OverlayKitModule.dependencies {
            #expect(dependency.layer < OverlayKitModule.layer, "\(dependency.name) is not below OverlayKit")
            #expect(dependency.name != OverlayKitModule.identifier)
        }
    }
}
