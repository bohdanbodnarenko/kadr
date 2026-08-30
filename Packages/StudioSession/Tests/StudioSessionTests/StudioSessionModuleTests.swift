import Testing
@testable import StudioSession

@Suite("StudioSession module")
struct StudioSessionModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(StudioSessionModule.identifier == "StudioSession")
        #expect(StudioSessionModule.layer == 1)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in StudioSessionModule.dependencies {
            #expect(dependency.layer < StudioSessionModule.layer, "\(dependency.name) is not below StudioSession")
            #expect(dependency.name != StudioSessionModule.identifier)
        }
    }
}
