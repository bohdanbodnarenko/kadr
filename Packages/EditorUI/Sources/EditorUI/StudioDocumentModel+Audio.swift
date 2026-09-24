import AppKit
import Foundation
import StudioRender
import StudioSession
import UniformTypeIdentifiers

/// Importing a cleaned soundtrack and exporting the edited one (docs/09 U3.3).
///
/// The two halves of the same loop: write the cut's audio out, run it through a tool that
/// has no API, bring the file back. The import is already the finished soundtrack, so it
/// lies flat on the edited timeline from zero rather than being re-cut through the clips.
@MainActor
public extension StudioDocumentModel {
    var hasImportedSoundtrack: Bool {
        session.soundtrackURL(for: edit) != nil
    }

    /// Opens a file picker for a replacement soundtrack.
    func chooseSoundtrack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .mpeg4Audio, .aiff]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to replace this recording's soundtrack."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importSoundtrack(from: url) }
    }

    /// Copies `url` into the session and uses it as the soundtrack.
    func importSoundtrack(from url: URL) async {
        guard await StudioAudioExporter.durationIfAudio(at: url) != nil else {
            failure = .noAudioTrack()
            return
        }
        do {
            let fileName = try session.replaceSoundtrack(copying: url)
            let display = url.deletingPathExtension().lastPathComponent
            change {
                $0.soundtrackFileName = fileName
                $0.soundtrackDisplayName = display
            }
            notice = "Using \(url.lastPathComponent) as the soundtrack."
        } catch {
            failure = .importFailed(error.localizedDescription)
        }
    }

    func removeSoundtrack() {
        guard hasImportedSoundtrack || edit.soundtrackFileName != nil else { return }
        // The file stays until the edit is committed on close, so undoing this still
        // finds it (docs/17 T-STU-9).
        change {
            $0.soundtrackFileName = nil
            $0.soundtrackDisplayName = nil
        }
    }

    /// Writes the edited soundtrack to a file the user picks.
    func exportEditedAudio() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio, .wav]
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        panel.nameFieldStringValue = "Soundtrack"
        panel.message = "Export the edited soundtrack, without the picture."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format: StudioAudioExporter.Format = url.pathExtension.lowercased() == "wav" ? .wav : .m4a
        Task { await exportEditedAudio(to: url, format: format) }
    }

    func exportEditedAudio(to url: URL, format: StudioAudioExporter.Format) async {
        do {
            try await StudioAudioExporter().export(
                screen: session.screenURL,
                clips: edit.clips,
                soundtrack: session.soundtrackURL(for: edit),
                to: url,
                format: format,
                mutesAudio: edit.mutesAudio,
                mixesToMono: edit.mixesToMono
            )
            notice = "Saved the soundtrack."
        } catch StudioAudioExporter.ExportError.noAudioTrack {
            failure = .noAudioTrack()
        } catch StudioAudioExporter.ExportError.cancelled {
            return
        } catch {
            failure = .audioExportFailed(error.localizedDescription)
        }
    }
}
