import Testing
@testable import Shared

@Suite("Shared module")
struct SharedModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(SharedModule.identifier == "Shared")
        #expect(SharedModule.layer == 0)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in SharedModule.dependencies {
            #expect(dependency.layer < SharedModule.layer, "\(dependency.name) is not below Shared")
            #expect(dependency.name != SharedModule.identifier)
        }
    }
}
