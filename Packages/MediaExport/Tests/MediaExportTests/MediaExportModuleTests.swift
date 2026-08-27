import Testing
@testable import MediaExport

@Suite("MediaExport module")
struct MediaExportModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(MediaExportModule.identifier == "MediaExport")
        #expect(MediaExportModule.layer == 1)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in MediaExportModule.dependencies {
            #expect(dependency.layer < MediaExportModule.layer, "\(dependency.name) is not below MediaExport")
            #expect(dependency.name != MediaExportModule.identifier)
        }
    }
}
