import Testing
@testable import SettingsKit

@Suite("SettingsKit module")
struct SettingsKitModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(SettingsKitModule.identifier == "SettingsKit")
        #expect(SettingsKitModule.layer == 1)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in SettingsKitModule.dependencies {
            #expect(dependency.layer < SettingsKitModule.layer, "\(dependency.name) is not below SettingsKit")
            #expect(dependency.name != SettingsKitModule.identifier)
        }
    }
}
