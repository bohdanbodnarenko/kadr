import AppKit
import Foundation
import MediaExport
import os
import Shared
import StudioRender
import StudioSession

/// Rendering the edit to a movie (docs/09 U3.3).
///
/// Its own file because an export is the one thing in the studio that takes minutes, cannot
/// be resumed, and writes somewhere the user chose — so it is the only operation here with a
/// lifecycle worth reading in one place: start it, watch it, stop it, and make sure that
/// whatever happens the destination is either the whole export or nothing at all.
@MainActor
public extension StudioDocumentModel {
    // MARK: - Exporting

    /// Puts the original recording on the clipboard as a file, the same way Quick Access
    /// Copy does. The edit is not in that file — Export is how the cuts and zooms leave.
    func copyOriginalToClipboard() {
        let url = session.screenURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    /// Renders the current edit, or reuses a stamped render, then copies it (docs/14 UX-31).
    func copyEditedToClipboard() async {
        guard exportTask == nil else { return }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-copy-\(UUID().uuidString)")
            .appendingPathExtension(exportSettings.filenameExtension)
        do {
            try await writeEditedRecording(to: destination)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([destination as NSURL])
            notice = "Copied the edit to the clipboard."
        } catch is CancellationError {
            return
        } catch {
            failure = .copyEditedFailed(error.localizedDescription)
        }
    }

    /// Renders the current edit for sharing (docs/14 UX-31).
    func shareEdited() async {
        guard exportTask == nil else { return }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-share-\(UUID().uuidString)")
            .appendingPathExtension(exportSettings.filenameExtension)
        do {
            try await writeEditedRecording(to: destination)
            guard let window = NSApp.keyWindow, let view = window.contentView else { return }
            let picker = NSSharingServicePicker(items: [destination])
            let anchor = NSRect(x: view.bounds.midX, y: view.bounds.maxY - 12, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        } catch is CancellationError {
            return
        } catch {
            failure = .shareEditedFailed(error.localizedDescription)
        }
    }

    /// Writes the current edit to `destination`, reusing a stamped render when possible.
    private func writeEditedRecording(to destination: URL) async throws {
        if reuseRenderedFile(at: destination) {
            return
        }
        exportProgress = 0
        flushDraft()
        try? document.commit(edit)
        defer { exportProgress = nil }
        let output = try await exportMedia(to: destination)
        recordStamp(output, at: destination)
    }

    /// Renders the edit to `destination`.
    ///
    /// The edit is committed first, so a finished export is also the point the draft is
    /// measured against: reopening after exporting shows what was exported.
    func export(to destination: URL) async {
        guard exportTask == nil else { return }
        let task = Task { await performExport(to: destination) }
        exportTask = task
        await task.value
        exportTask = nil
    }

    /// Whether a render is running.
    var isExporting: Bool {
        exportTask != nil
    }

    /// Stops an export and waits for it to finish tearing itself down (docs/11 S0.4).
    ///
    /// Waiting is the whole point. The renderer's `defer` is what deletes the half-written
    /// destination, and a `defer` only runs if something gives the Task a chance to unwind
    /// — so returning the instant `cancel()` is called would race the very cleanup this
    /// exists to guarantee, and leave behind exactly the truncated file it is meant to
    /// prevent.
    func cancelExport() async {
        guard let exportTask else { return }
        exportTask.cancel()
        await exportTask.value
    }

    /// Copies a previous render of this exact edit, if there is one and it is still there.
    private func reuseRenderedFile(at destination: URL) -> Bool {
        guard let stamp = document.renderStamp(),
              let digest = RenderStamp.digest(of: edit),
              stamp.matches(
                  editDigest: digest,
                  pixelSize: StudioRenderPlan(
                      edit: edit,
                      sourceSize: manifest.pixelSize,
                      maxLongestEdge: exportSettings.maxLongestEdge
                  ).outputSize,
                  settingsDigest: RenderStamp.digest(of: exportSettings)
              )
        else {
            return false
        }
        let source = URL(fileURLWithPath: stamp.outputPath)
        guard source.pathExtension.lowercased() == destination.pathExtension.lowercased() else {
            return false
        }
        guard source.standardizedFileURL != destination.standardizedFileURL else { return true }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            // A copy that fails is not a reason to refuse the export — render it again.
            logger.error("Could not reuse a finished render: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func performExport(to destination: URL) async {
        // The stamp is finally read (docs/11 S2).
        //
        // `renderStamp()` and `matches(editDigest:pixelSize:)` were written, tested and had
        // zero production callers, so "do not re-render an unchanged edit" was a feature
        // that existed only in the type system. Pressing Export twice on a ten-minute
        // recording re-rendered the whole thing.
        //
        // Copying rather than handing over the old path: the user picked *this*
        // destination, and telling them the export succeeded while pointing at a file
        // somewhere else is not the same thing as exporting.
        if reuseRenderedFile(at: destination) {
            notice = "That edit was already exported, so Kadr copied the finished file."
            if let transcript {
                writeCaptions(transcript, beside: destination)
            }
            return
        }

        exportProgress = 0
        // Any debounced draft write lands before the commit, so the two cannot disagree
        // about what was exported.
        flushDraft()
        try? document.commit(edit)

        do {
            let output = try await exportMedia(to: destination)
            recordStamp(output, at: destination)
            if let transcript {
                writeCaptions(transcript, beside: destination)
            }
            exportProgress = nil
        } catch is CancellationError {
            exportProgress = nil
            logger.info("Studio export cancelled")
        } catch StudioRenderer.RenderError.cancelled {
            exportProgress = nil
            logger.info("Studio export cancelled")
        } catch {
            exportProgress = nil
            failure = .exportFailed(error.localizedDescription)
            logger.error("Studio export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func exportMedia(to destination: URL) async throws -> StudioRenderer.Output {
        if exportSettings.container == .gif {
            return try await exportGIF(to: destination)
        }
        return try await renderMovie(to: destination)
    }

    private func renderMovie(to destination: URL) async throws -> StudioRenderer.Output {
        try await StudioRenderer().render(
            session: session,
            edit: edit,
            to: destination,
            options: exportSettings.rendererOptions,
            progress: { [weak self] value in
                Task { @MainActor in self?.exportProgress = value }
            }
        )
    }

    /// Movie first, then ImageIO (docs/03 §1.8). GIF is not a video container, so the
    /// renderer writes a throwaway MOV and the encoder samples it.
    private func exportGIF(to destination: URL) async throws -> StudioRenderer.Output {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-gif-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        let movie = try await renderMovie(to: temp)
        try Task.checkCancellation()
        _ = try await ImageIOGIFEncoder().encode(
            movieAt: temp,
            to: destination,
            options: exportSettings.gifOptions
        )
        return StudioRenderer.Output(
            fileURL: destination,
            pixelSize: movie.pixelSize,
            duration: movie.duration,
            frameCount: movie.frameCount
        )
    }

    private func recordStamp(_ output: StudioRenderer.Output, at destination: URL) {
        guard let digest = RenderStamp.digest(of: edit) else { return }
        try? document.write(RenderStamp(
            editDigest: digest,
            outputPath: destination.path,
            pixelSize: output.pixelSize,
            settingsDigest: RenderStamp.digest(of: exportSettings)
        ))
    }

    /// SRT and VTT beside the movie (docs/13 T2.2). Tiny, and the reason the transcript
    /// was persisted.
    private func writeCaptions(_ transcript: Transcript, beside destination: URL) {
        let base = destination.deletingPathExtension()
        let srt = CaptionExport.srt(from: transcript, timeline: edit.clips)
        let vtt = CaptionExport.vtt(from: transcript, timeline: edit.clips)
        try? srt.data(using: .utf8)?.write(to: base.appendingPathExtension("srt"), options: .atomic)
        try? vtt.data(using: .utf8)?.write(to: base.appendingPathExtension("vtt"), options: .atomic)
    }
}
