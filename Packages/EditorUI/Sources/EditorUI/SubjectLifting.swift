import Foundation

/// How the editor asks for a background removal (docs/04 §6, docs/06 M23).
///
/// Same shape as `RedactionAssisting`, and for the same reason: Vision lives in
/// HelperTools, the editor process calls this, and the window controller implements it
/// with `VisionClient`. EditorUI itself never opens an XPC connection.
@MainActor
public protocol SubjectLifting: AnyObject {
    /// Segments the capture and returns the mask as PNG data.
    ///
    /// `nil` means Vision found no subject — a normal answer for a screenshot of a
    /// spreadsheet, and something the editor says plainly rather than treating as a
    /// failure.
    func liftSubject() async throws -> Data?
}
