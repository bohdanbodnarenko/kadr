import Foundation
import os
import Shared
import StudioRender
import StudioSession

/// The state of one recording being edited in the studio (docs/09 U3).
///
/// Every edit goes through here, and every edit is non-destructive: the footage is never
/// touched, and what is saved is a description of what to do with it. That is what makes
/// undo total rather than best-effort — undo restores a value, not a series of reversals
/// somebody had to remember to write.
///
/// The draft is written beside the recording as the user works and only committed when they
/// export. Two files rather than one because "what I am in the middle of" and "what I have
/// decided" are different questions, and a crash halfway through an experiment should not
/// look like a decision (docs/09 U3.1).
@MainActor
@Observable
public final class StudioDocumentModel {
    @ObservationIgnored let logger = KadrLog.logger(.app)
    @ObservationIgnored public let session: RecordingSession
    @ObservationIgnored let document: SessionDocument

    /// What was captured alongside the footage.
    public let telemetry: InputTelemetry
    public let manifest: CaptureManifest

    /// The edit itself. Assigning records undo, so callers change it and nothing else.
    public private(set) var edit: StudioEdit

    /// Where the playhead is, in edited time.
    ///
    /// Computed over a stored value rather than a stored property with a `didSet` that
    /// clamps. `@Observable` rewrites stored properties into computed ones, so a `didSet`
    /// that assigns back to itself re-enters its own setter and recurses until the stack
    /// runs out — a crash, not a warning, and one that only appears once the property is
    /// actually written to.
    public var playhead: TimeInterval {
        get { storedPlayhead }
        set { storedPlayhead = min(max(newValue, 0), edit.duration) }
    }

    private var storedPlayhead: TimeInterval = 0

    /// The selected zoom cue, if one is.
    public var selectedZoom: ZoomCue.ID?

    /// Whether an export is running, and how far along.
    public internal(set) var exportProgress: Double?

    /// Set when something went wrong that the user should see.
    public var failure: String?

    /// Set when something worked and saying so is the whole feedback.
    public var notice: String?

    // MARK: - Speech

    /// Whether this language can be transcribed, once somebody has asked.
    ///
    /// Nil until asked, and asked only when the studio shows the speech controls. Checking
    /// at launch would consult the asset catalogue for every recording somebody opens,
    /// including the ones they never intend to transcribe.
    public private(set) var speechStatus: SpeechModelInstaller.Status?

    /// Progress of a model download the user started, or nil if none is running.
    public private(set) var installProgress: Double?

    /// Whether a transcription is running.
    public private(set) var isTranscribing = false

    /// Held so closing the window or quitting can stop it (docs/11 S0.4).
    ///
    /// Unstructured on purpose: an export outlives the save panel's completion handler, and
    /// nothing on the way in owns a scope that lasts as long as the render does.
    @ObservationIgnored var exportTask: Task<Void, Never>?

    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?

    @ObservationIgnored private var undoStack: [StudioEdit] = []
    @ObservationIgnored private var redoStack: [StudioEdit] = []

    /// How many steps back the studio remembers.
    ///
    /// Bounded because an edit is a whole value and keeping every one of them for a long
    /// session is a slow leak. Fifty is far past what anybody reaches for and still small.
    static let undoDepth = 50

    public init?(session: RecordingSession) {
        guard session.hasFootage else { return nil }
        self.session = session
        document = SessionDocument(session: session)
        telemetry = document.telemetry() ?? InputTelemetry()
        guard let manifest = document.manifest() else { return nil }
        self.manifest = manifest

        // The draft wins over the commit, so reopening lands where the user left off
        // rather than at the last thing they exported.
        edit = document.edit(StudioEdit.self) ?? StudioEdit.untouched(duration: manifest.duration)
        if document.edit(StudioEdit.self) == nil {
            // A recording made without a baked cursor has one drawn back; one made with a
            // cursor already in the picture does not, or it gets two.
            edit.showsCursor = !manifest.hasBakedCursor
        }
    }

    // MARK: - Editing

    /// Applies a change, recording it for undo.
    ///
    /// One funnel for every mutation. A model where some edits go through here and some
    /// assign directly is a model where undo works until it does not.
    public func change(_ mutate: (inout StudioEdit) -> Void) {
        var updated = edit
        mutate(&updated)
        guard updated != edit else { return }
        undoStack.append(edit)
        if undoStack.count > Self.undoDepth {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        edit = updated
        saveDraft()
    }

    public var canUndo: Bool {
        !undoStack.isEmpty
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edit)
        edit = previous
        clampAfterEdit()
        saveDraft()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        edit = next
        clampAfterEdit()
        saveDraft()
    }

    /// Keeps the playhead and the selection pointing at things that still exist.
    private func clampAfterEdit() {
        playhead = min(playhead, edit.duration)
        if let selectedZoom, !edit.zooms.contains(where: { $0.id == selectedZoom }) {
            self.selectedZoom = nil
        }
    }

    // MARK: - Zooms

    /// Adds a zoom over the playhead, anchored where the pointer was.
    ///
    /// Anchored at the pointer rather than the centre because a zoom to the middle of the
    /// screen is almost never what somebody wants: they are zooming to whatever they were
    /// doing, and where the pointer was is the best evidence of that available.
    public func addZoom(duration: TimeInterval = 3, magnification: Double = 2) {
        // A cue occupies its hold *and* both of its moves, so the span to fit inside the
        // recording is longer than the duration asked for. Fitting the hold alone puts the
        // move out past the end, where it never plays and the recording ends mid-zoom.
        let transition = Self.defaultTransition
        let footprint = duration + transition * 2
        let start = max(0, min(playhead, edit.duration - footprint))
        let available = max(edit.duration - start - transition * 2, 0.1)
        let anchor = pointerPosition(at: start) ?? centreOfFrame
        let cue = ZoomCue(
            start: start,
            duration: min(duration, available),
            magnification: magnification,
            anchor: .fixed(anchor),
            transitionDuration: transition
        )
        change { $0.zooms.append(cue) }
        selectedZoom = cue.id
    }

    /// How long a new cue takes to move in, and out again.
    static let defaultTransition: TimeInterval = 0.6

    /// Replaces the zooms with ones planned from the recorded clicks.
    ///
    /// Wholesale rather than additive: "add smart zooms" run twice should give the same
    /// result as run once, and appending would stack cues on top of each other.
    public func planSmartZooms() {
        let planner = ZoomCuePlanner()
        // Planned from the sidecar in source time, then rewritten onto the edited
        // timeline. Clicks already on the edited timeline would be planned twice against
        // cuts that have already moved them, and a second press of the button would not
        // be a no-op (docs/10 R0.2, R3.3).
        let planned = planner.cues(
            for: telemetry.clicks,
            in: manifest.pixelSize,
            duration: manifest.duration
        )
        let rebased = edit.clips.rebasing(planned)
        guard !rebased.isEmpty else {
            failure = "There were no click clusters to zoom to in this recording."
            return
        }
        change { $0.zooms = $0.clips.rebasing(planned) }
        selectedZoom = nil
    }

    public func removeSelectedZoom() {
        guard let selectedZoom else { return }
        change { $0.zooms.removeAll { $0.id == selectedZoom } }
        self.selectedZoom = nil
    }

    /// Updates one cue in place.
    public func updateZoom(_ id: ZoomCue.ID, _ mutate: (inout ZoomCue) -> Void) {
        change { edit in
            guard let index = edit.zooms.firstIndex(where: { $0.id == id }) else { return }
            mutate(&edit.zooms[index])
        }
    }

    /// Where the pointer was at an instant, in recorded pixels.
    ///
    /// Asked in edited time, because that is what the playhead is.
    private func pointerPosition(at time: TimeInterval) -> CGPoint? {
        let pointer = editedTelemetry.pointer
        return pointer.last { $0.time <= time }?.position ?? pointer.first?.position
    }

    /// The telemetry on the edited timeline (docs/10 R0.2).
    ///
    /// The sidecar is written in source time and everything in this model — the playhead,
    /// the cues, the clips — is in edited time. `ClipTimeline` is the only bridge between
    /// them, and this is the only place in the editor that crosses it.
    ///
    /// Cached against the clips it was built for. Rebasing walks every sample, and this is
    /// read while somebody drags a playhead.
    var editedTelemetry: InputTelemetry {
        if let cached = cachedEditedTelemetry, cached.clips == edit.clips {
            return cached.telemetry
        }
        let rebased = telemetry.rebased(to: edit.clips)
        cachedEditedTelemetry = (edit.clips, rebased)
        return rebased
    }

    @ObservationIgnored private var cachedEditedTelemetry: (clips: ClipTimeline, telemetry: InputTelemetry)?

    private var centreOfFrame: CGPoint {
        CGPoint(x: manifest.pixelSize.width / 2, y: manifest.pixelSize.height / 2)
    }

    // MARK: - Clips

    /// Splits the clip under the playhead.
    public func splitAtPlayhead() {
        change { $0.clips.split(atEdited: playhead) }
    }

    /// Removes the clip the playhead is in, if it is not the last one.
    ///
    /// The last clip stays: a timeline with nothing in it is not an edit, it is a deleted
    /// recording, and deleting a recording is not something a trim button should do.
    public func removeClipAtPlayhead() {
        let clips = edit.clips.clips
        guard clips.count > 1 else {
            failure = "This is the only clip left. Delete the recording itself if that is what you meant."
            return
        }
        guard let index = clipIndex(at: playhead) else { return }
        change {
            var remaining = $0.clips.clips
            remaining.remove(at: index)
            $0.clips = ClipTimeline(clips: remaining)
        }
        playhead = min(playhead, edit.duration)
    }

    /// Sets the speed of the clip under the playhead.
    public func setSpeedAtPlayhead(_ speed: Double) {
        guard let index = clipIndex(at: playhead) else { return }
        let id = edit.clips.clips[index].id
        change { $0.clips.setSpeed(speed, for: id) }
        playhead = min(playhead, edit.duration)
    }

    /// Which clip contains an edited-time instant.
    func clipIndex(at time: TimeInterval) -> Int? {
        var elapsed: TimeInterval = 0
        for (index, clip) in edit.clips.clips.enumerated() {
            let next = elapsed + clip.editedDuration
            if time < next || index == edit.clips.clips.count - 1 {
                return index
            }
            elapsed = next
        }
        return nil
    }

    // MARK: - Presets

    public func apply(_ preset: StudioPreset) {
        change { $0 = preset.applied(to: $0) }
    }

    // MARK: - Speech

    /// Finds out whether this language can be transcribed.
    ///
    /// Cheap, and safe to call repeatedly: it reads the system's catalogue and never
    /// downloads. Called when the speech controls appear so a model installed in System
    /// Settings since the window opened is noticed.
    public func refreshSpeechStatus() async {
        speechStatus = await SpeechModelInstaller().status()
    }

    /// Downloads the language model, because the user pressed the button that says so.
    ///
    /// The only thing in the studio that touches the network, and it is entirely optional:
    /// everything else in this window works with the machine unplugged, and a failed or
    /// cancelled download leaves the studio exactly as it was.
    public func installSpeechModel() {
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
    public func cancelSpeechModelInstall() {
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
    public func tidySpeech() async {
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
            guard !edit.clips.isEdited else {
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

    // MARK: - Saving

    /// Writes the draft. Failures are logged rather than surfaced.
    ///
    /// A dialog every time an autosave misses would be worse than the miss: the user is in
    /// the middle of something, the work is still on screen, and the next keystroke tries
    /// again. What must not happen silently is losing an *export*, and that reports.
    private func saveDraft() {
        do {
            try document.writeDraft(edit)
        } catch {
            logger.error("Could not autosave the studio edit: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The guard `tidySpeech` applies before it rebuilds the timeline.
    ///
    /// Its own method so a test can reach it: the rest of `tidySpeech` needs a microphone,
    /// a permission grant and a speech model, and the refusal needs none of those — which
    /// is exactly the split that let the bug through in the first place.
    func refuseTidyIfEditedForTesting() {
        guard edit.clips.isEdited else { return }
        failure = Self.tidyRefusal
    }

    static let tidyRefusal = "Speech tidying works on a recording you have not cut or re-timed yet. "
        + "Undo your clip edits first, or trim the pauses by hand."

    /// Records that the window closed on purpose (docs/09 U3.1).
    ///
    /// The draft says "somebody was in the middle of this" and the commit says "somebody
    /// stopped on purpose", and the difference between them is the entire definition of a
    /// session a crash interrupted. Without this every session anyone ever opened would
    /// look unfinished forever, and a recovery prompt that is always showing is one nobody
    /// reads.
    ///
    /// The draft stays. It is what reopening reads first, and after a clean close the two
    /// agree — so keeping it costs nothing and losing it would throw away the position the
    /// user left off at.
    public func commitOnClose() {
        do {
            try document.commit(edit)
        } catch {
            logger.error("Could not commit the studio edit: \(error.localizedDescription, privacy: .public)")
        }
    }
}
