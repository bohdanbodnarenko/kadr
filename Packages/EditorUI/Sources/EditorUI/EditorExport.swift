import Foundation

/// What the editor's export controls ask the window controller for (docs/03 §3).
///
/// Top level rather than nested in `EditorRootView`, because the document model reports
/// failures against one of these and a model that has to name a view type to describe its
/// own state is a layering mistake waiting to be copied.
public enum EditorExportAction: Equatable, Sendable {
    case copy
    /// Flattened image, even when annotations are selected (CleanShot ⌘⇧C).
    case copyFlattened
    case copyWithoutAnnotations
    case save
    /// Flattened image to a path the user picks (CleanShot §8.5).
    case saveAs
    /// Write a re-editable `.kadr` rather than a flattened image (docs/06 M24).
    case saveProject
    case print
    case pin
    case share
    case insertImage
    case insertFromClipboard

    /// Whether finishing this action means something is on the pasteboard.
    public var isCopy: Bool {
        switch self {
        case .copy, .copyFlattened, .copyWithoutAnnotations: true
        default: false
        }
    }

    /// Whether the result of this action is a file at a path.
    public var writesAFile: Bool {
        switch self {
        case .save, .saveAs, .saveProject: true
        default: false
        }
    }

    /// What the progress chip says while this is running.
    public var progressTitle: String {
        switch self {
        case .copy, .copyFlattened, .copyWithoutAnnotations: "Copying…"
        case .save, .saveAs: "Saving…"
        case .saveProject: "Saving the project…"
        case .print: "Preparing to print…"
        case .pin: "Pinning…"
        case .share: "Preparing to share…"
        case .insertImage, .insertFromClipboard: "Inserting…"
        }
    }
}

/// How an export ended.
///
/// A `Bool` would have been enough for the toast and wrong for everything else: cancelling
/// a save panel is not a failure, and showing "Copied" after one would be a lie of the same
/// kind this whole change exists to remove (docs/14 UX-26).
public enum EditorExportOutcome: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed
}

/// An export that did not happen, and what the user can do about it (docs/14 UX-26).
public struct EditorExportFailure: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// What was being attempted, so Retry knows what to retry.
    public var action: EditorExportAction
    public var message: String

    public init(action: EditorExportAction, message: String) {
        self.action = action
        self.message = message
    }

    /// A failed save can be retried somewhere else; a failed copy cannot.
    public var offersAnotherLocation: Bool {
        action.writesAFile
    }

    public var title: String {
        switch action {
        case .copy, .copyFlattened, .copyWithoutAnnotations: "Kadr could not copy this capture."
        case .save, .saveAs: "Kadr could not save this capture."
        case .saveProject: "Kadr could not save the project."
        case .print: "Kadr could not print this capture."
        case .pin: "Kadr could not pin this capture."
        case .share: "Kadr could not share this capture."
        case .insertImage, .insertFromClipboard: "Kadr could not insert that image."
        }
    }
}

public extension EditorRootView.ExportAction {
    var exportAction: EditorExportAction {
        switch self {
        case .copy: .copy
        case .copyFlattened: .copyFlattened
        case .copyWithoutAnnotations: .copyWithoutAnnotations
        case .save: .save
        case .saveAs: .saveAs
        case .saveProject: .saveProject
        case .print: .print
        case .pin: .pin
        case .share: .share
        case .insertImage: .insertImage
        case .insertFromClipboard: .insertFromClipboard
        }
    }
}

public extension EditorExportAction {
    var rootAction: EditorRootView.ExportAction {
        switch self {
        case .copy: .copy
        case .copyFlattened: .copyFlattened
        case .copyWithoutAnnotations: .copyWithoutAnnotations
        case .save: .save
        case .saveAs: .saveAs
        case .saveProject: .saveProject
        case .print: .print
        case .pin: .pin
        case .share: .share
        case .insertImage: .insertImage
        case .insertFromClipboard: .insertFromClipboard
        }
    }
}
