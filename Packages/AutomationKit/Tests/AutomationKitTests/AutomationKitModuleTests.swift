import Testing
@testable import AutomationKit

@Suite("AutomationKit module")
struct AutomationKitModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(AutomationKitModule.identifier == "AutomationKit")
        #expect(AutomationKitModule.layer == 1)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in AutomationKitModule.dependencies {
            #expect(dependency.layer < AutomationKitModule.layer, "\(dependency.name) is not below AutomationKit")
            #expect(dependency.name != AutomationKitModule.identifier)
        }
    }
}
