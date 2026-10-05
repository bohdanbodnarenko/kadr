import AnnotationModel
import CoreGraphics
import Foundation
import os
import Shared

/// Modifier keys the canvas passes down. Kept as a value so the model stays free of
/// AppKit and can be driven from a test.
public struct EditorModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// ⇧ — constrain to a square, a circle or 45° angles.
    public static let constrain = EditorModifiers(rawValue: 1 << 0)
    /// ⌥ — draw from the centre.
    public static let fromCenter = EditorModifiers(rawValue: 1 << 1)
    /// ⌘ — add to the selection rather than replacing it.
    public static let extendSelection = EditorModifiers(rawValue: 1 << 2)
}

/// The editor's state: a document, the current tool, and the drag in progress.
///
/// All of the "what does this gesture mean" logic lives here rather than in the view, so
/// every tool's behaviour is testable without a window — which for nine tools with
/// modifier variants is the difference between covered and hoped-for.
@MainActor
@Observable
public final class EditorDocumentModel {
    @ObservationIgnored private let logger = KadrLog.logger(.overlay)

    /// The document itself. Observers are told about it through `document`'s accessors.
    @ObservationIgnored private var storedDocument: AnnotationDocument

    /// Bumped on every write to `document`, published or not.
    ///
    /// The canvas compares this rather than the command list: comparing two 128-deep
    /// histories' worth of commands per SwiftUI update was itself a cost on the drag path.
    @ObservationIgnored public private(set) var documentRevision: UInt64 = 0
    /// The last revision observers were told about.
    @ObservationIgnored private var publishedRevision: UInt64 = 0
    /// True while the canvas is applying a pointer drag (docs/10 R1).
    @ObservationIgnored private var defersDocumentPublishing = false
    /// What `selection`, `canUndo` and `canRedo` observers last saw, so they are told
    /// only when those actually change — not on every edit to the document around them.
    @ObservationIgnored private var publishedSelection: Set<AnnotationID> = []
    @ObservationIgnored private var publishedCanUndo = false
    @ObservationIgnored private var publishedCanRedo = false

    /// The annotated capture.
    ///
    /// Hand-written accessors rather than plain observed storage, for the drag path. A
    /// drag rewrites the document on every mouse-moved event, and every view that read
    /// anything from it — the toolbar, the style pane, the look inspector and the canvas
    /// representable — was re-evaluated on each one, on top of the canvas updating its own
    /// layers in place. While the canvas applies a pointer drag, writes here are kept from
    /// observers (`withDocumentPublishingDeferred`) and published once when the pointer
    /// comes up. Every other write — undo, an inspector edit, a keystroke — is published
    /// as it happens, exactly as before.
    ///
    /// Views that only need the selection or the undo state read `selection`, `canUndo`
    /// and `canRedo`, which are published on their own and only when they change.
    public internal(set) var document: AnnotationDocument {
        get {
            access(keyPath: \.document)
            return storedDocument
        }
        set {
            documentRevision &+= 1
            if defersDocumentPublishing {
                storedDocument = newValue
            } else {
                publishedRevision = documentRevision
                withMutation(keyPath: \.document) {
                    storedDocument = newValue
                }
            }
            publishDerivedState()
        }
        _modify {
            documentRevision &+= 1
            if defersDocumentPublishing {
                yield &storedDocument
            } else {
                publishedRevision = documentRevision
                _$observationRegistrar.willSet(self, keyPath: \.document)
                defer { _$observationRegistrar.didSet(self, keyPath: \.document) }
                yield &storedDocument
            }
            publishDerivedState()
        }
    }

    public var tool: EditorTool = .select
    @ObservationIgnored var pasteCascadeCount = 0
    public var styleMemory = StyleMemory()
    /// The emoji the sticker tool places on the next click (docs/03 §3 P2).
    public var stickerEmoji = "😀"
    /// Pixel scale of Copy/Save relative to the capture. 1 is native; smaller
    /// values downscale the export without changing the canvas (docs/03 §3 P2).
    public var exportScale: CGFloat = 1 {
        didSet {
            let clamped = min(max(exportScale, 0.25), 1)
            if exportScale != clamped {
                exportScale = clamped
            }
        }
    }

    /// A text annotation that was just placed and should open the in-place editor.
    ///
    /// The canvas consumes this on mouse-up. Placing the box is not the end of the
    /// gesture — typing is — so the text tool stays armed until that editor commits.
    public internal(set) var pendingTextEditID: AnnotationID?
    /// A text box placed by the text tool and not yet committed: placing it and typing into
    /// it fold into one undo step when the editor commits (docs/18 ED-5).
    @ObservationIgnored var freshTextID: AnnotationID?

    /// Auto-redaction review. These sit outside the document until the user accepts
    /// (docs/03 §3, docs/06 M18) — detecting a secret must not blur it on its own.
    public internal(set) var redactionCandidates: [RedactionCandidate] = []
    public internal(set) var recognizedLines: [RecognizedLine] = []
    /// Word boxes from the same OCR pass, for the smart highlighter (docs/03 §3 P2).
    public internal(set) var recognizedWords: [RecognizedWord] = []
    /// Image-space boxes the highlighter snaps to. Empty until OCR has run.
    public internal(set) var highlightBoxes: [CGRect] = []
    /// The word or line currently under the pointer, while the highlighter is armed.
    public internal(set) var hoveredHighlightBox: CGRect?
    public internal(set) var isFindingRedactions = false
    public var redactionQuery = ""
    public internal(set) var redactionAssistError: String?
    public internal(set) var isRedactionReviewActive = false

    /// The straight lines found in the base image, for the measure tool (docs/06 M21).
    ///
    /// Supplied by the canvas, which is the only thing here that holds the pixels. Empty
    /// until then, and an empty set simply means nothing snaps — measuring still works.
    public internal(set) var edgeCandidates: EdgeCandidates = .none
    /// True while `loadEdgesInBackground` is reading the capture.
    @ObservationIgnored var isLoadingEdges = false
    /// How close a measurement endpoint has to be to a detected line before it snaps, in
    /// base-image points. Zero turns snapping off.
    public var edgeSnapTolerance: CGFloat = 6

    /// Background removal, which is a round trip to the helper (docs/06 M23).
    public internal(set) var isLiftingSubject = false
    public internal(set) var subjectLiftError: String?

    /// The export running right now, if one is (docs/14 UX-26).
    ///
    /// A 5K render takes long enough that "nothing happened" is a reasonable thing for the
    /// user to conclude, so the chrome says what is happening while the work is off the
    /// main actor and the window still takes input.
    public internal(set) var runningExport: EditorExportAction?

    /// An export that did not happen, until the user retries or dismisses it.
    public var exportFailure: EditorExportFailure?

    /// Set when the smart highlighter could not read the capture and fell back to
    /// freehand (docs/14 UX-30B). Cleared by the chrome after it has been read.
    public var highlighterFallback: String?

    /// Set after a successful pasteboard write so the toast appears only then (docs/14 UX-26).
    public internal(set) var showsCopiedToast = false

    /// When on, existing annotations stay put so drawing tools do not accidentally grab
    /// them (CleanShot §8.1, docs/03 §3 P2).
    public var isCanvasLocked = false

    /// Whether the inspector column is visible (docs/14 UX-28).
    public var isInspectorPresented = true

    /// The annotation being drawn right now. It lives outside the document until the
    /// mouse comes up, so a half-drawn arrow never lands in the undo history.
    public internal(set) var draft: AnnotationCommand?
    /// The marquee being dragged in select mode.
    public internal(set) var marquee: CGRect?

    /// Where the current pointer gesture started, or nil between gestures. Not observed:
    /// the canvas reads it on every SwiftUI update to know whether it is mid-drag.
    @ObservationIgnored var dragOrigin: CGPoint?
    /// The selected annotations exactly as they were when the drag began.
    ///
    /// The move is recomputed from these on every event rather than accumulated onto the
    /// live ones: applying an origin-relative delta to already-moved commands compounds,
    /// and the selection accelerates away from the pointer (docs/07 C2).
    var dragStartCommands: [AnnotationID: AnnotationCommand] = [:]
    /// Arrows bound to the dragged annotations, precomputed at gesture start (docs/16 ED-5).
    var dragDependents: Set<AnnotationID> = []
    var isMovingSelection = false
    /// Snapping for the current move (docs/18 ED-7): the boxes it can land on, how close
    /// counts (image points, set by the canvas from its zoom), and the guides to draw.
    @ObservationIgnored var snapTargets: [CGRect] = []
    @ObservationIgnored public var snapThreshold: CGFloat = 6
    @ObservationIgnored public internal(set) var snapGuides: [SnapGuides.Guide] = []
    /// ⌥ was held when the move began: the first movement drags copies.
    @ObservationIgnored var duplicatesOnDrag = false
    /// The handle currently being dragged, if this gesture is a resize rather than a move.
    var resizeHandle: SelectionHandle?
    var resizeStartBounds: CGRect?
    /// The crop handle being dragged in crop mode (docs/09 U1.8).
    var cropDragHandle: CropHandle?
    var cropDragStartRect: CGRect?
    @ObservationIgnored var cropBaseline: CropSpec?
    /// A highlighter click that has not yet become a freehand drag (docs/03 §3 P2).
    var pendingSmartHighlight: CGRect?
    /// True while an inspector slider owns the open document gesture, so releasing the
    /// slider (or clicking the canvas) closes that undo step without colliding with a drag.
    @ObservationIgnored var inspectorStyleGesture = false

    /// The document's commands as they were when the work was last saved.
    ///
    /// Comparing against a snapshot rather than counting edits means undoing back to where
    /// the user started is *clean* again — which is what they will expect when the window
    /// stops asking to save.
    @ObservationIgnored private var savedCommands: [AnnotationCommand]
    @ObservationIgnored private var savedOrientation: CanvasOrientation

    /// The crop rect while a crop handle is being dragged.
    ///
    /// Published on its own because the crop bar shows the live size, and the document —
    /// which it would otherwise read — is not published mid-drag.
    public internal(set) var liveCropRect: CGRect?

    public init(document: AnnotationDocument) {
        storedDocument = document
        savedCommands = document.commands
        savedOrientation = document.orientation
        publishedSelection = document.selection
        publishedCanUndo = document.canUndo
        publishedCanRedo = document.canRedo
        styleMemory = StyleMemoryStore.load()
    }

    /// True while the canvas has a pointer gesture open, from mouse-down to mouse-up.
    public var isPointerGestureActive: Bool {
        dragOrigin != nil
    }

    /// Runs `body` with its document writes kept from observers.
    ///
    /// For the canvas's per-event drag path only: the canvas updates its own layers for
    /// those writes, and everything else catches up at `publishDeferredDocumentChanges`.
    func withDocumentPublishingDeferred<Result>(_ body: () -> Result) -> Result {
        let wasDeferring = defersDocumentPublishing
        defersDocumentPublishing = true
        defer { defersDocumentPublishing = wasDeferring }
        return body()
    }

    /// Tells observers about any document writes they have not heard about yet.
    public func publishDeferredDocumentChanges() {
        guard publishedRevision != documentRevision, !defersDocumentPublishing else { return }
        publishedRevision = documentRevision
        withMutation(keyPath: \.document) {}
    }

    /// Publishes the cheap derived values, each only if it changed.
    private func publishDerivedState() {
        let selection = storedDocument.selection
        if selection != publishedSelection {
            withMutation(keyPath: \.selection) {
                publishedSelection = selection
            }
        }
        let canUndo = storedDocument.canUndo
        if canUndo != publishedCanUndo {
            withMutation(keyPath: \.canUndo) {
                publishedCanUndo = canUndo
            }
        }
        let canRedo = storedDocument.canRedo
        if canRedo != publishedCanRedo {
            withMutation(keyPath: \.canRedo) {
                publishedCanRedo = canRedo
            }
        }
    }

    /// Records where the opaque capture sits, once it has been measured off the main actor.
    ///
    /// Not an edit: it describes the pixels, so it is neither undoable nor unsaved work.
    public func adoptVisibleBounds(_ rect: CGRect?) {
        guard storedDocument.baseImage.visibleBounds == nil, rect != nil else { return }
        document.adoptVisibleBounds(rect)
    }

    /// Whether there is work in this window that only exists in this window (docs/07 M7).
    public var hasUnsavedChanges: Bool {
        document.commands != savedCommands || document.orientation != savedOrientation
    }

    /// Replaces the whole document, for restoring work a previous session left behind.
    ///
    /// The restored state counts as unsaved, because it is: the autosave is a recovery
    /// copy, not a save the user made.
    public func replaceDocument(_ replacement: AnnotationDocument) {
        document = replacement
    }

    /// Records that the current state has been written somewhere durable.
    ///
    /// Called for a project save and for an image export alike: exporting a flattened PNG
    /// loses re-editability, but the user has just deliberately produced the artefact they
    /// came for, and asking them to save again on the way out would be nagging.
    public func markSaved() {
        savedCommands = document.commands
        savedOrientation = document.orientation
    }

    public var selection: Set<AnnotationID> {
        get {
            access(keyPath: \.selection)
            return storedDocument.selection
        }
        set { document.selection = newValue }
    }

    /// Layers to refresh while a drag is in flight: the selection plus bound arrows.
    var layersNeedingUpdateDuringMove: Set<AnnotationID> {
        dragDependents.union(selection)
    }

    func captureArrowDependents() {
        dragDependents = ArrowDependents.layersNeedingUpdate(
            duringMoveOf: Set(dragStartCommands.keys),
            in: document.commands
        )
    }

    public var canUndo: Bool {
        access(keyPath: \.canUndo)
        return storedDocument.canUndo
    }

    public var canRedo: Bool {
        access(keyPath: \.canRedo)
        return storedDocument.canRedo
    }

    public func undo() {
        document.undo()
    }

    public func redo() {
        document.redo()
    }

    /// Rotate the capture 90° clockwise (docs/03 §3 P2).
    public func rotateClockwise() {
        document.rotateClockwise()
    }

    /// Mirror the capture left-to-right (docs/03 §3 P2).
    public func flipHorizontal() {
        document.flipHorizontal()
    }

    /// Mirror the capture top-to-bottom (CleanShot §8.2).
    public func flipVertical() {
        document.flipVertical()
    }

    // MARK: - Selection

    /// Moves the selection by a delta from where the drag started.
    ///
    /// Offsets are computed from the drag's origin rather than accumulated per event, so a
    /// fast drag cannot drift away from the pointer.
    public func moveSelection(by delta: CGSize) {
        guard !isCanvasLocked else { return }
        // Read the selection out first: `perform` hands the command list back as `inout`,
        // and reading another property of the same document inside that closure is an
        // exclusive-access violation that traps at runtime.
        let selection = document.selection
        guard !selection.isEmpty else { return }
        document.perform { commands in
            for index in commands.indices where selection.contains(commands[index].id) {
                commands[index] = Self.translated(commands[index], by: delta)
            }
        }
    }

    /// Arrow-key nudging (docs/03 §3).
    public func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        moveSelection(by: CGSize(width: dx, height: dy))
    }

    public func deleteSelection() {
        guard !isCanvasLocked else { return }
        document.remove(document.selection)
    }

    public func selectAll() {
        document.selection = Set(document.commands.filter(\.isSelectable).map(\.id))
        // ⌘A is a selection gesture, so the pointer has to be in Select — otherwise
        // the next click would draw rather than move what was just selected.
        if tool != .select {
            tool = .select
        }
    }

    // MARK: - Z-order

    public func bringSelectionToFront() {
        document.bringToFront(document.selection)
    }

    public func bringSelectionForward() {
        document.bringForward(document.selection)
    }

    public func sendSelectionBackward() {
        document.sendBackward(document.selection)
    }
}
