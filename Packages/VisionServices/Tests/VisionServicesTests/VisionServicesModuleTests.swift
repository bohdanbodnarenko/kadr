import Testing
@testable import VisionServices

@Suite("VisionServices module")
struct VisionServicesModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(VisionServicesModule.identifier == "VisionServices")
        #expect(VisionServicesModule.layer == 1)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in VisionServicesModule.dependencies {
            #expect(dependency.layer < VisionServicesModule.layer, "\(dependency.name) is not below VisionServices")
            #expect(dependency.name != VisionServicesModule.identifier)
        }
    }
}
