import Foundation
import os
import Shared
import StudioRender
import StudioSession

/// Transcribing a recording and cutting the filler words out of it (docs/09 U3.6).
///
/// Its own file because it is the one part of the studio that talks to something outside
/// the app: `SpeechModelInstaller` asks macOS to fetch a speech model, which is one of the
/// two places in Kadr that reach the network at all (CLAUDE.md rule 1). Keeping it together
/// makes that boundary visible rather than buried among the sliders.
@MainActor
public extension StudioDocumentModel {
    // MARK: - Speech

    /// Finds out whether this language can be transcribed.
    ///
    /// Cheap, and safe to call repeatedly: it reads the system's catalogue and never
    /// downloads. Called when the speech controls appear so a model installed in System
    /// Settings since the window opened is noticed.
    func refreshSpeechStatus() async {
        speechStatus = await SpeechModelInstaller().status()
    }

    /// Downloads the language model, because the user pressed the button that says so.
    ///
    /// The only thing in the studio that touches the network, and it is entirely optional:
    /// everything else in this window works with the machine unplugged, and a failed or
    /// cancelled download leaves the studio exactly as it was.
    func installSpeechModel() {
        guard installTask == nil else { return }
        installProgress = 0

        // `@MainActor` on the task rather than hopping inside it: the model is main-actor
        // isolated, so every line below already belongs here, and the alternative is
        // sending `self` across an isolation boundary it never actually crosses.
        installTask = Task { @MainActor [self] in
            defer {
                installTask = nil
                installProgress = nil
                progressObservation = nil
            }
            do {
                try await SpeechModelInstaller().install { progress in
                    Task { @MainActor [weak self] in self?.observe(progress) }
                }
                await refreshSpeechStatus()
                notice = "The language model is installed. Speech is ready to use."
            } catch is CancellationError {
                // Silent: the user cancelled it, so they already know.
            } catch {
                failure = "The language model could not be downloaded: \(error.localizedDescription)"
            }
        }
    }

    /// Stops a download in progress.
    func cancelSpeechModelInstall() {
        installTask?.cancel()
        installTask = nil
        installProgress = nil
        progressObservation = nil
    }

    /// Follows the system's `Progress` so the bar moves.
    private func observe(_ progress: Progress) {
        progressObservation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor [weak self] in self?.installProgress = fraction }
        }
    }

    /// Transcribes the recording and cuts the filler words and long pauses out.
    ///
    /// The cuts land as clip boundaries like every other edit, so they are undoable in one
    /// step and the footage is untouched. Nothing here downloads anything: if the model is
    /// not installed this reports that and stops, which is why the button that offers to
    /// install one is a separate button.
    func tidySpeech() async {
        guard !isTranscribing else { return }
        guard await AudioTranscriber.requestAuthorization() else {
            failure = "Kadr needs permission to use speech recognition. Grant it in System Settings ▸ "
                + "Privacy & Security ▸ Speech Recognition."
            return
        }
        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let transcript = try await AudioTranscriber().transcribe(audioAt: session.screenURL)
            let planner = TranscriptCutPlanner()
            // The transcript is in source time — it came from the recording's audio, which
            // knows nothing about the cuts — so the cuts are planned against the source's
            // own length rather than the edited one (docs/10 R0.2).
            let cuts = planner.cuts(for: transcript, duration: manifest.duration)
            guard !cuts.isEmpty else {
                notice = "There were no filler words or long pauses to remove."
                return
            }
            // `applying` rebuilds a timeline from scratch at natural speed, so it can only
            // be used on an untouched one. Applying it over an existing edit silently threw
            // away every cut and speed change the user had already made.
            guard !edit.clips.isEdited(ofRecordingLasting: manifest.duration) else {
                failure = Self.tidyRefusal
                return
            }
            let timeline = planner.applying(cuts, to: manifest.duration)
            guard !timeline.clips.isEmpty, timeline.editedDuration > 0 else {
                notice = "Tidying would leave nothing to play. The recording was left as it is."
                return
            }
            change { $0.clips = timeline }
            playhead = min(playhead, edit.duration)
            notice = "Removed \(cuts.count) \(cuts.count == 1 ? "passage" : "passages")."
        } catch TranscriptionError.unavailableOnDevice {
            await refreshSpeechStatus()
            failure = "There is no speech model on this Mac for your language yet."
        } catch TranscriptionError.noAudioTrack {
            failure = "This recording has no sound in it."
        } catch {
            failure = "The recording could not be transcribed: \(error.localizedDescription)"
        }
    }
}
