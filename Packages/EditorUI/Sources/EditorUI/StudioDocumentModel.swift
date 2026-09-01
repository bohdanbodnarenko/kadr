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
    public internal(set) var speechStatus: SpeechModelStatus?

    /// Progress of a model download the user started, or nil if none is running.
    public internal(set) var installProgress: Double?

    /// Progress of a transcription, 0…1, or nil if none is running.
    public internal(set) var transcriptionProgress: Double?

    /// Whether a transcription is running.
    public internal(set) var isTranscribing = false

    /// The persisted (or just-produced) transcript for this session.
    public internal(set) var transcript: Transcript?

    /// Cuts waiting for the user to review (docs/13 T0.4).
    public var pendingCuts: [ProposedCut] = []

    /// Which pending cuts are selected to apply. All on by default.
    public var selectedCutIDs: Set<UUID> = []

    /// Set when applying the selected cuts would remove more than ~40% of the recording.
    public internal(set) var requiresCutConfirmation = false

    public internal(set) var dictationSettingsNeeded = false
    public internal(set) var supportedLocales: [String] = []
    public var speechLocaleIdentifier = ""
    public var transcriptQuery = ""
    public internal(set) var chapters: [ChapterMark] = []

    public var isSpeechBusy: Bool {
        isTranscribing || installTask != nil
    }

    /// Held so closing the window or quitting can stop it (docs/11 S0.4).
    ///
    /// Unstructured on purpose: an export outlives the save panel's completion handler, and
    /// nothing on the way in owns a scope that lasts as long as the render does.
    /// The playback loop, or nil when paused (docs/08 §2 item 10).
    ///
    /// Its own presence *is* `isPlaying`: two pieces of state that have to agree about one
    /// thing is a way for them to disagree, and the one that would have gone wrong here is a
    /// play button stuck on after a cancelled task.
    @ObservationIgnored var playbackTask: Task<Void, Never>?

    @ObservationIgnored var exportTask: Task<Void, Never>?

    @ObservationIgnored var installTask: Task<Void, Never>?
    @ObservationIgnored var transcribeTask: Task<Void, Never>?
    @ObservationIgnored var progressObservation: NSKeyValueObservation?
    @ObservationIgnored var transcriber: any Transcribing

    @ObservationIgnored private var undoStack: [StudioEdit] = []
    @ObservationIgnored private var redoStack: [StudioEdit] = []

    /// How many steps back the studio remembers.
    ///
    /// Bounded because an edit is a whole value and keeping every one of them for a long
    /// session is a slow leak. Fifty is far past what anybody reaches for and still small.
    static let undoDepth = 50

    public init?(session: RecordingSession, transcriber: (any Transcribing)? = nil) {
        guard session.hasFootage else { return nil }
        self.session = session
        document = SessionDocument(session: session)
        telemetry = document.telemetry() ?? InputTelemetry()
        guard let manifest = document.manifest() else { return nil }
        self.manifest = manifest
        self.transcriber = transcriber ?? HelperTranscriber()

        // The draft wins over the commit, so reopening lands where the user left off
        // rather than at the last thing they exported.
        edit = document.edit(StudioEdit.self) ?? StudioEdit.untouched(duration: manifest.duration)
        if document.edit(StudioEdit.self) == nil {
            // A recording made without a baked cursor has one drawn back; one made with a
            // cursor already in the picture does not, or it gets two.
            edit.showsCursor = !manifest.hasBakedCursor
        }

        let hash = try? AudioContentHash.hash(fileAt: session.screenURL)
        transcript = document.transcript(matchingHash: hash)
        if let transcript {
            chapters = ChapterMarks.marks(from: transcript, duration: manifest.duration)
        }
    }

    // MARK: - Editing

    /// Applies a change, recording it for undo.
    ///
    /// One funnel for every mutation. A model where some edits go through here and some
    /// assign directly is a model where undo works until it does not.
    /// - Parameter gesture: names a continuous interaction — one drag of one slider — so
    ///   its ticks collapse into a single undo step (docs/11 S2).
    ///
    ///   Without it every tick pushed its own snapshot, and a `Slider` sends one per pixel
    ///   of travel: a single drag of the Size slider consumed the whole fifty-deep undo
    ///   stack, so Undo afterwards nudged the bubble by a hair and the state before the drag
    ///   was gone. This is docs/07 C2 repeating in the studio — the annotation editor
    ///   learned the same lesson in U0.2, where it coalesces by keeping a spec's identity
    ///   across inspector edits.
    ///
    ///   Any change with a different gesture — or none — starts a new step, which is what
    ///   makes releasing one slider and dragging another two undo steps rather than one.
    public func change(coalescingAs gesture: String? = nil, _ mutate: (inout StudioEdit) -> Void) {
        var updated = edit
        mutate(&updated)
        guard updated != edit else { return }

        let continues = gesture != nil && gesture == activeGesture && !undoStack.isEmpty
        if !continues {
            undoStack.append(edit)
            if undoStack.count > Self.undoDepth {
                undoStack.removeFirst()
            }
        }
        activeGesture = gesture
        redoStack.removeAll()
        edit = updated
        saveDraft()
    }

    /// The interaction currently being coalesced, if one is.
    @ObservationIgnored private var activeGesture: String?

    public var canUndo: Bool {
        !undoStack.isEmpty
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    public func undo() {
        // Whatever gesture was in flight is over: the next slider tick must start its own
        // step rather than merging into the one just undone.
        activeGesture = nil
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edit)
        edit = previous
        clampAfterEdit()
        saveDraft()
    }

    public func redo() {
        activeGesture = nil
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
    ///
    /// - Parameter gesture: names a continuous interaction, so dragging a cue along the
    ///   timeline is one undo step rather than one per pixel of travel (docs/11 S2).
    public func updateZoom(
        _ id: ZoomCue.ID,
        coalescingAs gesture: String? = nil,
        _ mutate: (inout ZoomCue) -> Void
    ) {
        change(coalescingAs: gesture) { edit in
            guard let index = edit.zooms.firstIndex(where: { $0.id == id }) else { return }
            mutate(&edit.zooms[index])
        }
    }

    /// Moves a cue to a new start, keeping it inside the recording.
    ///
    /// A cue's start could not be changed at all: `addZoom` dropped it at the playhead and
    /// the inspector offered magnification, hold and move but not *when*. Putting a zoom
    /// half a second earlier meant deleting it and adding another, which throws away
    /// everything else the user had set on it.
    ///
    /// Clamped so the whole cue — its hold *and* both of its moves — still fits. A cue that
    /// runs off the end never finishes playing, and the recording ends mid-zoom.
    public func moveZoom(_ id: ZoomCue.ID, to start: TimeInterval) {
        guard let cue = edit.zooms.first(where: { $0.id == id }) else { return }
        let footprint = cue.duration + cue.transitionDuration * 2
        let latest = max(edit.duration - footprint, 0)
        updateZoom(id, coalescingAs: "zoom.start.\(id)") { $0.start = min(max(start, 0), latest) }
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

    // MARK: - Presets

    public func apply(_ preset: StudioPreset) {
        change { $0 = preset.applied(to: $0) }
    }

    // MARK: - Saving

    /// Writes the draft. Failures are logged rather than surfaced.
    ///
    /// A dialog every time an autosave misses would be worse than the miss: the user is in
    /// the middle of something, the work is still on screen, and the next keystroke tries
    /// again. What must not happen silently is losing an *export*, and that reports.
    private func saveDraft() {
        // Throttled, not debounced (docs/11 S2).
        //
        // A slider drag calls `change` per pixel of travel, and each call used to write the
        // whole draft atomically on the MainActor — a temporary file, a rename and an fsync
        // per tick, while the preview was trying to redraw on the same actor.
        //
        // A plain debounce would have been wrong, and the existing tests said so: with one,
        // a session that had just been edited had no draft on disk yet, so it did not look
        // unfinished to the recovery prompt and reopening it found nothing to restore. The
        // first change in a burst therefore still writes immediately, and only the ones
        // treading on its heels are collapsed into a single trailing write. Durability is
        // unchanged; what goes away is writing the same file forty times a second.
        let now = ContinuousClock.now
        if let last = lastDraftWrite, now - last < Self.draftInterval {
            draftSave?.cancel()
            draftSave = Task { [weak self] in
                try? await Task.sleep(for: Self.draftInterval)
                guard !Task.isCancelled else { return }
                self?.writeDraftNow()
            }
            return
        }
        writeDraftNow()
    }

    /// How close together two writes have to be before the second one waits.
    static let draftInterval: Duration = .milliseconds(400)

    @ObservationIgnored private var draftSave: Task<Void, Never>?
    @ObservationIgnored private var lastDraftWrite: ContinuousClock.Instant?

    /// Writes the draft immediately, cancelling any debounced write.
    ///
    /// Called wherever the model is about to be committed or let go, because a debounce is
    /// only safe if something reliably flushes it.
    func flushDraft() {
        guard draftSave != nil else { return }
        draftSave?.cancel()
        draftSave = nil
        writeDraftNow()
    }

    private func writeDraftNow() {
        lastDraftWrite = ContinuousClock.now
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
        guard edit.clips.isEdited(ofRecordingLasting: manifest.duration) else { return }
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
        flushDraft()
        do {
            try document.commit(edit)
        } catch {
            logger.error("Could not commit the studio edit: \(error.localizedDescription, privacy: .public)")
        }
    }
}
