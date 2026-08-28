import CoreGraphics
import Shared

/// How the editor asks for redaction candidates (docs/04 §6).
///
/// Vision stays in HelperTools. The editor process calls this; the window controller
/// implements it with `VisionClient`. EditorUI itself never opens an XPC connection.
@MainActor
public protocol RedactionAssisting: AnyObject {
    func analyzeForRedaction(_ image: CGImage) async throws -> VisionAnalysis
}
