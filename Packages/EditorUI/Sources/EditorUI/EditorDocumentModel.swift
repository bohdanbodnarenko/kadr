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

    public internal(set) var document: AnnotationDocument
    public var tool: EditorTool = .select
    public var styleMemory = StyleMemory()

    /// A text annotation that was just placed and should open the in-place editor.
    ///
    /// The canvas consumes this on mouse-up. Placing the box is not the end of the
    /// gesture — typing is — so the text tool stays armed until that editor commits.
    public internal(set) var pendingTextEditID: AnnotationID?

    /// Auto-redaction review. These sit outside the document until the user accepts
    /// (docs/03 §3, docs/06 M18) — detecting a secret must not blur it on its own.
    public internal(set) var redactionCandidates: [RedactionCandidate] = []
    public internal(set) var recognizedLines: [RecognizedLine] = []
    public internal(set) var isFindingRedactions = false
    public var redactionQuery = ""
    public internal(set) var redactionAssistError: String?
    public internal(set) var isRedactionReviewActive = false

    /// The straight lines found in the base image, for the measure tool (docs/06 M21).
    ///
    /// Supplied by the canvas, which is the only thing here that holds the pixels. Empty
    /// until then, and an empty set simply means nothing snaps — measuring still works.
    public internal(set) var edgeCandidates: EdgeCandidates = .none
    /// How close a measurement endpoint has to be to a detected line before it snaps, in
    /// base-image points. Zero turns snapping off.
    public var edgeSnapTolerance: CGFloat = 6

    /// Background removal, which is a round trip to the helper (docs/06 M23).
    public internal(set) var isLiftingSubject = false
    public internal(set) var subjectLiftError: String?

    /// The annotation being drawn right now. It lives outside the document until the
    /// mouse comes up, so a half-drawn arrow never lands in the undo history.
    public internal(set) var draft: AnnotationCommand?
    /// The marquee being dragged in select mode.
    public internal(set) var marquee: CGRect?

    var dragOrigin: CGPoint?
    /// The selected annotations exactly as they were when the drag began.
    ///
    /// The move is recomputed from these on every event rather than accumulated onto the
    /// live ones: applying an origin-relative delta to already-moved commands compounds,
    /// and the selection accelerates away from the pointer (docs/07 C2).
    var dragStartCommands: [AnnotationID: AnnotationCommand] = [:]
    var isMovingSelection = false
    /// The handle currently being dragged, if this gesture is a resize rather than a move.
    var resizeHandle: SelectionHandle?
    var resizeStartBounds: CGRect?
    /// The crop handle being dragged in crop mode (docs/09 U1.8).
    var cropDragHandle: CropHandle?
    var cropDragStartRect: CGRect?
    /// True while an inspector slider owns the open document gesture, so releasing the
    /// slider (or clicking the canvas) closes that undo step without colliding with a drag.
    @ObservationIgnored var inspectorStyleGesture = false

    /// The document's commands as they were when the work was last saved.
    ///
    /// Comparing against a snapshot rather than counting edits means undoing back to where
    /// the user started is *clean* again — which is what they will expect when the window
    /// stops asking to save.
    @ObservationIgnored private var savedCommands: [AnnotationCommand]

    public init(document: AnnotationDocument) {
        self.document = document
        savedCommands = document.commands
    }

    /// Whether there is work in this window that only exists in this window (docs/07 M7).
    public var hasUnsavedChanges: Bool {
        document.commands != savedCommands
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
    }

    public var selection: Set<AnnotationID> {
        get { document.selection }
        set { document.selection = newValue }
    }

    public var canUndo: Bool {
        document.canUndo
    }

    public var canRedo: Bool {
        document.canRedo
    }

    public func undo() {
        document.undo()
    }

    public func redo() {
        document.redo()
    }

    // MARK: - Selection

    /// Moves the selection by a delta from where the drag started.
    ///
    /// Offsets are computed from the drag's origin rather than accumulated per event, so a
    /// fast drag cannot drift away from the pointer.
    public func moveSelection(by delta: CGSize) {
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

    // MARK: - Drafting

    func makeDraft(_ annotationTool: AnnotationTool, at point: CGPoint) -> AnnotationCommand? {
        let stroke = styleMemory.stroke(for: annotationTool)
        switch annotationTool {
        case .arrow:
            return .arrow(ArrowSpec(start: point, end: point, head: styleMemory.lastArrowHead, stroke: stroke))
        case .shape:
            return .shape(ShapeSpec(
                kind: styleMemory.lastShapeKind,
                rect: CGRect(origin: point, size: .zero),
                stroke: stroke,
                fill: styleMemory.fill(for: .shape)
            ))
        case .line:
            return .line(LineSpec(start: point, end: point, stroke: stroke))
        case .freehand:
            return .freehand(FreehandSpec(points: [point], stroke: stroke))
        case .highlighter:
            return .highlighter(HighlighterSpec(points: [point], stroke: stroke))
        case .text:
            return .text(TextSpec(
                rect: CGRect(origin: point, size: CGSize(width: 200, height: 40)),
                style: styleMemory.lastTextStyle
            ))
        case .redaction:
            return .redaction(RedactionSpec(
                rect: CGRect(origin: point, size: .zero),
                style: styleMemory.lastRedactionStyle
            ))
        case .crop:
            return .crop(CropSpec(rect: CGRect(origin: point, size: .zero)))
        case .measure:
            return .measure(MeasureSpec(
                start: point,
                end: point,
                measuresBox: styleMemory.lastMeasuresBox,
                stroke: stroke
            ))
        case .counter, .beautify, .camera, .progressiveBlur, .watermark, .subjectLift, .image:
            return nil
        }
    }

    func update(
        _ draft: inout AnnotationCommand,
        from origin: CGPoint,
        to point: CGPoint,
        modifiers: EditorModifiers
    ) {
        switch draft {
        case var .arrow(spec):
            spec.end = modifiers.contains(.constrain) ? Self.snapped(point, from: origin) : point
            draft = .arrow(spec)
        case var .line(spec):
            spec.end = modifiers.contains(.constrain) ? Self.snapped(point, from: origin) : point
            draft = .line(spec)
        case var .shape(spec):
            spec.rect = Self.rect(from: origin, to: point, modifiers: modifiers)
            draft = .shape(spec)
        case var .redaction(spec):
            spec.rect = Self.rect(from: origin, to: point, modifiers: modifiers)
            draft = .redaction(spec)
        case var .crop(spec):
            spec.rect = Self.rect(from: origin, to: point, modifiers: modifiers)
            draft = .crop(spec)
        case var .text(spec):
            spec.rect = Self.rect(from: origin, to: point, modifiers: modifiers)
            draft = .text(spec)
        case var .freehand(spec):
            spec.points.append(point)
            draft = .freehand(spec)
        case var .highlighter(spec):
            spec.points.append(point)
            draft = .highlighter(spec)
        case var .measure(spec):
            spec.end = modifiers.contains(.constrain) ? Self.snapped(point, from: origin) : point
            draft = .measure(spec)
        case .counter, .beautify, .camera, .progressiveBlur, .watermark, .subjectLift, .image:
            break
        }
    }

    func rememberStyle(of command: AnnotationCommand) {
        switch command {
        case let .arrow(spec):
            styleMemory.remember(spec.stroke, for: .arrow)
            styleMemory.lastArrowHead = spec.head
        case let .shape(spec):
            styleMemory.remember(spec.stroke, for: .shape)
            styleMemory.remember(spec.fill, for: .shape)
            styleMemory.lastShapeKind = spec.kind
        case let .line(spec):
            styleMemory.remember(spec.stroke, for: .line)
        case let .freehand(spec):
            styleMemory.remember(spec.stroke, for: .freehand)
        case let .highlighter(spec):
            styleMemory.remember(spec.stroke, for: .highlighter)
        case let .text(spec):
            styleMemory.lastTextStyle = spec.style
        case let .redaction(spec):
            styleMemory.lastRedactionStyle = spec.style
        case let .measure(spec):
            styleMemory.remember(spec.stroke, for: .measure)
            styleMemory.lastMeasuresBox = spec.measuresBox
        case .counter, .crop, .beautify, .camera, .progressiveBlur, .watermark, .subjectLift,
             .image:
            break
        }
    }

    // MARK: - Geometry

    /// A rect from a drag, honouring ⇧ (square) and ⌥ (from the centre).
    static func rect(from origin: CGPoint, to point: CGPoint, modifiers: EditorModifiers) -> CGRect {
        var corner = point
        if modifiers.contains(.constrain) {
            let side = max(abs(point.x - origin.x), abs(point.y - origin.y))
            corner = CGPoint(
                x: origin.x + (point.x >= origin.x ? side : -side),
                y: origin.y + (point.y >= origin.y ? side : -side)
            )
        }
        if modifiers.contains(.fromCenter) {
            return CGRect(
                x: origin.x - abs(corner.x - origin.x),
                y: origin.y - abs(corner.y - origin.y),
                width: abs(corner.x - origin.x) * 2,
                height: abs(corner.y - origin.y) * 2
            )
        }
        return CGRect(
            x: min(origin.x, corner.x),
            y: min(origin.y, corner.y),
            width: abs(corner.x - origin.x),
            height: abs(corner.y - origin.y)
        )
    }

    /// ⇧ on a line or arrow snaps to the nearest 45°.
    static func snapped(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// Whether a finished drag actually drew something.
    ///
    /// A click with no drag leaves a zero-sized annotation. Testing the *geometry* rather
    /// than the bounding box matters: a bounding box includes the stroke, so a zero-sized
    /// shape with a four-point stroke looks non-empty and would be kept.
    static func isWorthKeeping(_ command: AnnotationCommand) -> Bool {
        // Below this a drag is a click that wobbled.
        let minimum: CGFloat = 2

        switch command {
        case let .arrow(spec):
            return hypot(spec.end.x - spec.start.x, spec.end.y - spec.start.y) >= minimum
        case let .line(spec):
            return hypot(spec.end.x - spec.start.x, spec.end.y - spec.start.y) >= minimum
        case let .shape(spec):
            return spec.rect.width >= minimum || spec.rect.height >= minimum
        case let .redaction(spec):
            return spec.rect.width >= minimum && spec.rect.height >= minimum
        case let .crop(spec):
            return spec.rect.width >= minimum && spec.rect.height >= minimum
        case let .freehand(spec):
            return spec.points.count > 1
        case let .highlighter(spec):
            return spec.points.count > 1
        case let .measure(spec):
            // A click that did not drag is not a failed measurement — it is a request to
            // measure the element under the pointer, handled in `pointerUp`.
            return spec.length >= minimum
        // A text box starts empty by design; the user types into it next.
        case .text:
            return true
        case .counter, .beautify, .camera, .progressiveBlur, .watermark, .subjectLift, .image:
            return true
        }
    }
}
