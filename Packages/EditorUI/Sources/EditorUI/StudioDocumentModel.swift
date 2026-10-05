import AnnotationModel
import AppKit
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
    ///
    /// Every assignment goes through `replaceEdit(with:)`, which keeps the derived caches
    /// and the clip under the playhead in step. A `didSet` would say the same thing more
    /// quietly, but it would also run from inside `init` before the model is whole.
    public private(set) var edit: StudioEdit

    /// The single writer of `edit`.
    func replaceEdit(with next: StudioEdit) {
        let clipsChanged = next.clips != edit.clips
        edit = next
        if clipsChanged {
            cachedClipEnds = nil
            cachedClickTimes = nil
            cachedEditedTelemetry = nil
            cachedPlannedZooms = nil
        }
        refreshPlayheadDerivedState()
    }

    /// Zooms planned from the clicks, for the suggestion layer (`+ZoomSuggestions`).
    @ObservationIgnored var cachedPlannedZooms: [ZoomCue]?
    /// Suggestions waved away this session, by source start in milliseconds.
    var dismissedZoomSuggestions: Set<Int> = []
    /// Whether the zoom lane draws suggestions. Remembered across recordings.
    var showsZoomSuggestions = UserDefaults.standard.object(forKey: showsZoomSuggestionsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsZoomSuggestions, forKey: Self.showsZoomSuggestionsKey) }
    }

    nonisolated static let showsZoomSuggestionsKey = "studio.showsZoomSuggestions"

    /// Where the playhead is, in edited time.
    ///
    /// Stored on `playheadClock`, not on this model (docs/11 S2). Playback writes it thirty
    /// times a second, and every SwiftUI body that had read it — the timeline's whole
    /// geometry, the transport bar, the inspector's form, the transcript — was invalidated
    /// on every one of those writes, because an `@Observable` property invalidates whoever
    /// read it. Keeping the time on its own tiny observable means only the leaf views that
    /// actually draw the time (the needle, the clock label, the active word) re-render per
    /// tick; everything else reads `currentClipIndex` and friends, which change only when
    /// the answer does.
    ///
    /// Computed rather than a stored property with a `didSet` that clamps. `@Observable`
    /// rewrites stored properties into computed ones, so a `didSet` that assigns back to
    /// itself re-enters its own setter and recurses until the stack runs out — a crash, not
    /// a warning, and one that only appears once the property is actually written to.
    public var playhead: TimeInterval {
        get { playheadClock.time }
        set {
            let clamped = min(max(newValue, 0), edit.duration)
            guard clamped != playheadClock.time else { return }
            playheadClock.time = clamped
            refreshPlayheadDerivedState()
        }
    }

    /// The observable that owns the playhead and hover times. Views that draw the time
    /// every frame read it here, so nothing else is invalidated per tick.
    @ObservationIgnored public let playheadClock = StudioPlayhead()

    /// The index of the clip under the playhead, or nil when there are no clips.
    ///
    /// Stored and only written when the index actually changes, so the inspector's form and
    /// the timeline's selection highlight re-render when the playhead crosses a cut rather
    /// than on every playback tick.
    public private(set) var currentClipIndex: Int?

    /// Whether the playhead sits strictly inside the edit, which is when trimming to it
    /// means anything. Stored for the same reason as `currentClipIndex`.
    public private(set) var playheadIsInsideEdit = false

    /// Re-derives the state that depends on the playhead, writing only what changed.
    ///
    /// The comparisons are the point: an `@Observable` write invalidates readers even when
    /// the value is equal, so assigning unconditionally here would put the per-tick storm
    /// straight back.
    func refreshPlayheadDerivedState() {
        let time = playheadClock.time
        let index = clipIndex(at: time)
        if index != currentClipIndex {
            currentClipIndex = index
        }
        let inside = time > 0 && time < edit.duration
        if inside != playheadIsInsideEdit {
            playheadIsInsideEdit = inside
        }
    }

    /// The selected zoom cue, if one is.
    public var selectedZoom: ZoomCue.ID?

    /// The selected clip, if one is. Edge-trimming and the speed slider talk to this.
    public var selectedClip: Clip.ID?

    /// How a forthcoming export should be encoded. Remembered across recordings.
    public var exportSettings = StudioExportSettings.remembered

    /// The zoom being aimed on the preview, if one is (docs/09 U3.3).
    ///
    /// Aiming shows the recording *unzoomed* with the cue's target drawn on it, because a
    /// target drawn over an already-zoomed picture is a rectangle inside itself. Like
    /// `isCropping` this is what the user is doing, not part of the edit: it is never
    /// saved and never undone.
    public var aimingZoom: ZoomCue.ID?

    public var isAimingZoom: Bool {
        aimingZoom != nil
    }

    /// Whether the preview is in crop mode: the full recording is shown with a handle
    /// overlay, rather than four sliders in the inspector.
    public var isCropping = false
    /// The crop being dragged, in normalised source space. Committed on Done.
    public var workingCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    public var cropAspect: CropAspectPreset = .free

    /// Timeline hover, for a skim thumbnail. Does not move the playhead or the main preview
    /// (docs/16 STU-C5, user preference: no seek-on-hover).
    ///
    /// Forwarded to `playheadClock` for the same reason the playhead is: the timeline writes
    /// it on every mouse move, and on this model that invalidated the root view, the
    /// preview and the timeline together.
    public var hoverPreviewTime: TimeInterval? {
        get { playheadClock.hoverTime }
        set {
            guard newValue != playheadClock.hoverTime else { return }
            playheadClock.hoverTime = newValue
        }
    }

    /// Whether an export is running, and how far along.
    /// Drives the Dock tile, not a view: hiding the inspector froze it (docs/17 T-STU-12).
    public internal(set) var exportProgress: Double? {
        didSet {
            if NSApp != nil {
                StudioDockProgress.update(exportProgress)
            }
        }
    }

    /// When the running render began, for the time-left estimate (docs/18 STU-13).
    @ObservationIgnored var exportStartedAt: Date?
    /// The file the last export wrote, for the in-window "Exported" banner (docs/18 STU-13).
    public var lastExportedURL: URL?

    /// Whether the inspector column is open, and whether the export sheet is up.
    ///
    /// On the model rather than in the view's `@State` so the window's menu commands — ⌘I
    /// and ⌘E, which arrive through the responder chain — can reach them. A menu item is
    /// the one place a keyboard command works whatever the window's layout happens to be,
    /// and the transport bar's controls move between three arrangements.
    /// Its state is remembered across windows and launches (docs/18 STU-12).
    public var isInspectorPresented = StudioDocumentModel.rememberedInspectorPresented {
        didSet { UserDefaults.standard.set(isInspectorPresented, forKey: Self.inspectorPresentedKey) }
    }

    public var showsExportOptions = false

    /// Set when something went wrong that the user should see.
    public var failure: StudioFailurePresentation? {
        didSet { Self.announce(failure.map { $0.title + " " + $0.message }, unless: oldValue == failure) }
    }

    /// Set when something worked and saying so is the whole feedback.
    public var notice: String? {
        didSet {
            Self.announce(notice, unless: oldValue == notice)
            if notice != oldValue {
                noticeAction = nil
            }
        }
    }

    /// A button the notice offers, set after the notice itself (docs/18 STU-14).
    public var noticeAction: StudioNoticeAction?

    /// The look last applied from the preset bar.
    var storedAppliedPresetID: UUID?
    @ObservationIgnored var presetStore = StudioPresetStore()

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
    /// What Tidy looks for (docs/17 T-STU-6): an "um" is never content, a pause may be.
    public var tidyRemovesFillers = true
    public var tidyShortensPauses = true
    /// The J/K/L speed: −2, −1, 0, 1 or 2 (docs/17 T-STU-11).
    @ObservationIgnored var shuttleSpeed = 0

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

    /// The preview's player and its clock (docs/08 §2 item 10).
    @ObservationIgnored let playback = StudioPlaybackController()
    /// Whether the edit is playing. Written only by `playback`, which is the one thing that
    /// knows whether the player is actually rolling.
    public internal(set) var isPlaying = false

    /// Held so closing the window or quitting can stop it (docs/11 S0.4).
    ///
    /// Unstructured on purpose: an export outlives the save panel's completion handler, and
    /// nothing on the way in owns a scope that lasts as long as the render does.
    @ObservationIgnored var exportTask: Task<Void, Never>?
    /// The soundtrack export (T-STU-9) and the Share button the picker hangs off (T-STU-4).
    @ObservationIgnored var audioExportTask: Task<Void, Never>?
    @ObservationIgnored weak var shareAnchorView: NSView?
    /// Validating and loading the persisted transcript; cancelled on close.
    @ObservationIgnored var transcriptLoadTask: Task<Void, Never>?
    /// The last integer percent published to `exportProgress`, so a render's per-frame
    /// callbacks only reach the main actor's observers when the bar would visibly move.
    @ObservationIgnored var publishedExportPercent: Int?

    @ObservationIgnored var installTask: Task<Void, Never>?
    @ObservationIgnored var transcribeTask: Task<Void, Never>?
    @ObservationIgnored var progressObservation: NSKeyValueObservation?
    @ObservationIgnored var transcriber: any Transcribing

    @ObservationIgnored private var undoStack: [(edit: StudioEdit, name: String)] = []
    @ObservationIgnored private var redoStack: [StudioEdit] = []

    /// How many steps back the studio remembers.
    ///
    /// Bounded because an edit is a whole value and keeping every one of them for a long
    /// session is a slow leak. Fifty is far past what anybody reaches for and still small.
    static let undoDepth = 50

    public init?(
        session: RecordingSession,
        transcriber: (any Transcribing)? = nil,
        presetStore: StudioPresetStore = StudioPresetStore()
    ) {
        guard session.hasFootage else { return nil }
        self.session = session
        document = SessionDocument(session: session)
        draftWriter = StudioDraftWriter(document: document)
        telemetry = document.telemetry() ?? InputTelemetry()
        guard let manifest = document.manifest() else { return nil }
        self.manifest = manifest
        self.transcriber = transcriber ?? HelperTranscriber()
        self.presetStore = presetStore

        // Moved aside before anything can autosave over it (docs/17 T-STU-9).
        let backups = document.backUpUnreadableEdits(StudioEdit.self)

        // The draft wins over the commit, so reopening lands where the user left off
        // rather than at the last thing they exported.
        edit = document.edit(StudioEdit.self) ?? StudioEdit.untouched(duration: manifest.duration)
        if document.edit(StudioEdit.self) == nil {
            // A recording made without a baked cursor has one drawn back; one made with a
            // cursor already in the picture does not, or it gets two.
            edit.showsCursor = !manifest.hasBakedCursor
        }

        refreshPlayheadDerivedState()
        if let backup = backups.first {
            failure = .unreadableEditBackedUp(backup.lastPathComponent)
        }

        // The transcript arrives after the window does (docs/11 S2). Validating it means
        // hashing the whole of `screen.mov`, which on a long recording was seconds of
        // spinning cursor on the main thread before the studio drew anything. Everything
        // that reads `transcript` already handles nil — it is nil for every recording that
        // was never transcribed — so arriving late changes nothing but the wait.
        transcriptLoadTask = Task { [weak self] in
            await self?.loadTranscript()
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
    public func change(
        named name: String = "Edit",
        coalescingAs gesture: String? = nil,
        _ mutate: (inout StudioEdit) -> Void
    ) {
        var updated = edit
        mutate(&updated)
        guard updated != edit else { return }

        let continues = gesture != nil && gesture == activeGesture && !undoStack.isEmpty
        if !continues {
            undoStack.append((edit: edit, name: name))
            if undoStack.count > Self.undoDepth {
                undoStack.removeFirst()
            }
        }
        activeGesture = gesture
        redoStack.removeAll()
        replaceEdit(with: updated)
        saveDraft()
    }

    /// A default look on a recording nobody has edited yet is the starting point, not a
    /// step they should have to undo to reach "as recorded".
    func adoptEditWithoutUndo(_ next: StudioEdit) {
        replaceEdit(with: next)
    }

    /// The interaction currently being coalesced, if one is.
    @ObservationIgnored private var activeGesture: String?

    public var undoMenuTitle: String {
        guard let last = undoStack.last else { return "Undo" }
        return "Undo \(last.name)"
    }

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
        replaceEdit(with: previous.edit)
        clampAfterEdit()
        saveDraft()
    }

    public func redo() {
        activeGesture = nil
        guard let next = redoStack.popLast() else { return }
        undoStack.append((edit: edit, name: "Redo"))
        replaceEdit(with: next)
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

    /// The telemetry on the edited timeline (docs/10 R0.2).
    ///
    /// The sidecar is written in source time and everything in this model — the playhead,
    /// the cues, the clips — is in edited time. `ClipTimeline` is the only bridge between
    /// them, and this is the only place in the editor that crosses it.
    ///
    /// Cached against the clips it was built for. Rebasing walks every sample, and this is
    /// read while somebody drags a playhead.
    ///
    /// Invalidated by `replaceEdit(with:)` when the clips change, rather than by comparing
    /// the whole timeline on every read — the comparison was itself O(clips) per tick.
    var editedTelemetry: InputTelemetry {
        if let cachedEditedTelemetry {
            return cachedEditedTelemetry
        }
        let rebased = telemetry.rebased(to: edit.clips)
        cachedEditedTelemetry = rebased
        return rebased
    }

    @ObservationIgnored private var cachedEditedTelemetry: InputTelemetry?

    /// Where each clip ends on the edited timeline, ascending. Built on demand, dropped
    /// whenever the clips change.
    var clipEnds: [TimeInterval] {
        if let cachedClipEnds {
            return cachedClipEnds
        }
        var elapsed: TimeInterval = 0
        let ends = edit.clips.clips.map { clip in
            elapsed += clip.editedDuration
            return elapsed
        }
        cachedClipEnds = ends
        return ends
    }

    @ObservationIgnored var cachedClipEnds: [TimeInterval]?

    /// Recorded clicks on the edited timeline.
    var editedClickTimes: [TimeInterval] {
        clickTimes.all
    }

    /// The zoom lane's click ticks: `editedClickTimes`, evenly thinned for drawing.
    var clickTicks: [TimeInterval] {
        clickTimes.ticks
    }

    /// The lane used to filter and map every recorded click — then decimate — in its body,
    /// on every render. Cached like `editedTelemetry`, and dropped with it.
    private var clickTimes: (all: [TimeInterval], ticks: [TimeInterval]) {
        if let cachedClickTimes {
            return cachedClickTimes
        }
        let all = editedTelemetry.clicks.filter(\.isDown).map(\.time)
        let computed = (all: all, ticks: Self.decimated(all, limit: Self.maximumClickTicks))
        cachedClickTimes = computed
        return computed
    }

    @ObservationIgnored var cachedClickTimes: (all: [TimeInterval], ticks: [TimeInterval])?

    // MARK: - Saving

    /// How close together two writes have to be before the second one waits.
    static let draftInterval: Duration = .milliseconds(400)

    /// Encodes and writes drafts off the main actor. See `StudioDocumentModel+Draft.swift`.
    @ObservationIgnored let draftWriter: StudioDraftWriter
    @ObservationIgnored var draftSave: Task<Void, Never>?
    @ObservationIgnored var lastDraftWrite: ContinuousClock.Instant?
    /// Bumped on every change, so a write can tell whether it is still the newest.
    @ObservationIgnored var draftGeneration = 0
    /// Whether this model has put a draft on disk yet. The first one is written in place.
    @ObservationIgnored var hasWrittenDraft = false
}
