import Testing
@testable import AnnotationRender

@Suite("AnnotationRender module")
struct AnnotationRenderModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(AnnotationRenderModule.identifier == "AnnotationRender")
        #expect(AnnotationRenderModule.layer == 2)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in AnnotationRenderModule.dependencies {
            #expect(dependency.layer < AnnotationRenderModule.layer, "\(dependency.name) is not below AnnotationRender")
            #expect(dependency.name != AnnotationRenderModule.identifier)
        }
    }
}
