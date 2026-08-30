import AnnotationModel
import AnnotationRender
import MediaExport
import Shared
import StudioRender
import StudioSession

/// Placeholder for the `EditorUI` package.
///
/// SwiftUI editor chrome (toolbars, inspector) hosting the AnnotationRender canvas. Editor app only.
///
/// Scaffolding only (milestone M0.1) — no behaviour lives here yet. The type exists so the
/// package, its dependency edges and its test target are wired up and verified by CI.
/// See `docs/04-swift-architecture.md` §2 for what belongs in this module.
public enum EditorUIModule {
    /// Stable identifier for the module; matches the package and product name.
    public static let identifier = "EditorUI"

    /// Position of this package in the dependency graph of docs/04 §2.
    /// A package may only depend on packages in a strictly lower layer.
    public static let layer = 3

    /// The packages this module links, resolved through their real symbols so the
    /// declared graph and the linked graph cannot drift apart.
    public static let dependencies: [(name: String, layer: Int)] = [
        (SharedModule.identifier, SharedModule.layer),
        (AnnotationModelModule.identifier, AnnotationModelModule.layer),
        (AnnotationRenderModule.identifier, AnnotationRenderModule.layer),
        (MediaExportModule.identifier, MediaExportModule.layer),
        (StudioSessionModule.identifier, StudioSessionModule.layer),
        (StudioRenderModule.identifier, StudioRenderModule.layer)
    ]
}
