import Testing
@testable import StudioRender

@Suite("StudioRender module")
struct StudioRenderModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(StudioRenderModule.identifier == "StudioRender")
        #expect(StudioRenderModule.layer == 2)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in StudioRenderModule.dependencies {
            #expect(dependency.layer < StudioRenderModule.layer, "\(dependency.name) is not below StudioRender")
            #expect(dependency.name != StudioRenderModule.identifier)
        }
    }
}
