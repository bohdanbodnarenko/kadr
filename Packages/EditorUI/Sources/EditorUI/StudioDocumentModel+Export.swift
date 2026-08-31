import Foundation
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
              stamp.matches(editDigest: digest, pixelSize: StudioRenderPlan(
                  edit: edit,
                  sourceSize: manifest.pixelSize
              ).outputSize)
        else {
            return false
        }
        let source = URL(fileURLWithPath: stamp.outputPath)
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
            if let transcript = transcript {
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
            let output = try await StudioRenderer().render(
                session: session,
                edit: edit,
                to: destination,
                progress: { [weak self] value in
                    Task { @MainActor in self?.exportProgress = value }
                }
            )
            guard let digest = RenderStamp.digest(of: edit) else {
                exportProgress = nil
                return
            }
            try? document.write(RenderStamp(
                editDigest: digest,
                outputPath: output.fileURL.path,
                pixelSize: output.pixelSize
            ))
            if let transcript = transcript {
                writeCaptions(transcript, beside: destination)
            }
            exportProgress = nil
        } catch is CancellationError {
            // The user asked for this, so it is not a failure to report back to them. The
            // renderer's `defer` has already removed the partial file.
            exportProgress = nil
            logger.info("Studio export cancelled")
        } catch StudioRenderer.RenderError.cancelled {
            exportProgress = nil
            logger.info("Studio export cancelled")
        } catch {
            exportProgress = nil
            failure = "The export failed: \(error.localizedDescription)"
            logger.error("Studio export failed: \(error.localizedDescription, privacy: .public)")
        }
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
