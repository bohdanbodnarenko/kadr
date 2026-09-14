import Foundation
import SettingsKit

/// What a card can do (docs/03 §2). Stubs are wired to the milestones that fill them in.
struct QuickAccessCardActions {
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var saveAs: () -> Void = {}
    var rotate: () -> Void = {}
    var flipHorizontal: () -> Void = {}
    var flipVertical: () -> Void = {}
    var scaleRetina: () -> Void = {}
    var annotate: () -> Void = {}
    var pin: () -> Void = {}
    var recognizeText: () -> Void = {}
    var delete: () -> Void = {}
    var dismiss: () -> Void = {}
    /// Resolves the file to hand to a receiver, finalising a staged capture on the way.
    /// Called when the drop asks for the bytes, never when the drag starts (docs/07 C1).
    var resolveForDrag: @MainActor @Sendable () -> URL? = { nil }
    /// The drag ended; `true` when a receiver took the file.
    var dragCompleted: @MainActor @Sendable (Bool) -> Void = { _ in }
    /// Turns a recording into a GIF (docs/03 §1.8). Only offered on a recording.
    var exportGIF: () -> Void = {}
    /// Re-encodes the capture smaller and copies it (docs/09 U2.4).
    var compress: () -> Void = {}
    /// Opens a recording in the trim window (docs/03 §1.8). Only offered on a recording.
    var trim: () -> Void = {}
    var trimAvailable = false
    /// Opens a recording in the studio (docs/09 U3). Offered only when the recording still
    /// has a session beside it — without one there is nothing to edit but the trim.
    var studio: () -> Void = {}
    var studioAvailable = false
    /// Hover pauses auto-dismiss; it does not claim the card (docs/03 §2).
    var setHovered: (Bool) -> Void = { _ in }
    /// Dragging pauses auto-dismiss until the drop finishes.
    var beginDrag: () -> Void = {}
    /// Tucks the stack into the peek tab (swipe toward the screen edge).
    var peek: () -> Void = {}
    /// Whether Annotate, Pin and OCR do anything yet.
    var annotateAvailable = false
    var pinAvailable = false
    var textAvailable = false

    /// Why an action cannot run right now, or nil when it can (docs/14 UX-24B).
    ///
    /// A reason rather than a flag, because the button stays live either way: a disabled
    /// glyph with "coming soon" in its tooltip is how "the editor is not installed" became
    /// invisible to everyone who does not hover. Pressing it now says what is wrong.
    var unavailableReason: (CardAction) -> ActionUnavailableReason? = { _ in nil }
    /// Shows why an action did nothing, in the overlay's own status banner.
    var reportUnavailable: (ActionUnavailableReason) -> Void = { _ in }
}
