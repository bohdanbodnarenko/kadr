import Foundation
import StudioSession

/// What one export renders, fixed when it starts (docs/17 T-STU-2).
///
/// A value, so nothing the user does while the render runs can reach it: the stamp,
/// the captions and the movie all describe the same edit.
struct StudioExportSnapshot: Sendable {
    let edit: StudioEdit
    let transcript: Transcript?
    let settings: StudioExportSettings
    /// A digest of `StudioRenderInputs`, or nil if it could not be encoded — in which
    /// case no finished render is ever reused.
    let inputsDigest: String?
}

/// Everything besides the edit and the export settings that changes the rendered pixels
/// (docs/17 T-STU-1).
///
/// Before this a render stamp hashed only the edit and the settings, so a tester who
/// updated to a build with a render fix was told "already exported" and handed the old
/// movie; a swapped wallpaper or a re-transcription did the same.
struct StudioRenderInputs: Encodable {
    var appVersion: String
    var appBuild: String
    var rendererVersion: Int
    var transcriptDigest: String?
    var wallpaper: String?
    var soundtrack: String?
}
