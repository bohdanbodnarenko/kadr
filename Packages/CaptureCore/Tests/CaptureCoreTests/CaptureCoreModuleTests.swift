import Testing
@testable import CaptureCore

@Suite("CaptureCore module")
struct CaptureCoreModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(CaptureCoreModule.identifier == "CaptureCore")
        #expect(CaptureCoreModule.layer == 1)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in CaptureCoreModule.dependencies {
            #expect(dependency.layer < CaptureCoreModule.layer, "\(dependency.name) is not below CaptureCore")
            #expect(dependency.name != CaptureCoreModule.identifier)
        }
    }
}
