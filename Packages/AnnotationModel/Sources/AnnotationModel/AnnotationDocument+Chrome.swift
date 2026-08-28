import CoreGraphics
import Foundation

/// The canvas chrome: beautify, the perspective camera, the progressive blur and the
/// background removal (docs/03 §3 P2, docs/09 U1.1–U1.3).
///
/// Split from the document's own file because chrome is edited through inspectors and
/// everything else through the pointer — and because four effects with the same
/// last-one-wins accessor and the same coalescing rule read better together than scattered
/// among the editing operations.
public extension AnnotationDocument {
    /// The beautify chrome in force, if any. The last one wins.
    var beautify: BeautifySpec? {
        commands.reversed().compactMap { command in
            if case let .beautify(spec) = command {
                return spec
            }
            return nil
        }.first
    }

    /// The background removal in force, if any. The last one wins.
    var subjectLift: SubjectLiftSpec? {
        commands.reversed().compactMap { command in
            if case let .subjectLift(spec) = command {
                return spec
            }
            return nil
        }.first
    }

    /// Replaces the background removal, or clears it. One undo step either way — unlike
    /// beautify's slider edits, this is a decision rather than a drag.
    mutating func setSubjectLift(_ spec: SubjectLiftSpec?) {
        var updated = commands
        updated.removeAll { command in
            if case .subjectLift = command {
                return true
            }
            return false
        }
        if let spec {
            // Behind everything else: it changes the base image, so it belongs at the
            // bottom of the stack alongside the other canvas chrome.
            updated.insert(.subjectLift(spec), at: 0)
        }
        guard updated != commands else { return }
        pushHistory(updated)
    }

    /// The perspective camera in force, if any. The last one wins.
    var camera: AnnotationCameraSpec? {
        commands.reversed().compactMap { command in
            if case let .camera(spec) = command {
                return spec
            }
            return nil
        }.first
    }

    /// Where the camera puts the card's corners, or nil when there is no camera to apply.
    ///
    /// Measured against the *card* rather than the capture, so a tilted screenshot leans
    /// within its beautified frame rather than within its own bounds — which is the
    /// composition the effect exists for (docs/09 U1.2).
    var cameraGeometry: AnnotationCameraGeometry? {
        guard let camera, !camera.isIdentity else { return nil }
        let cardRect = beautifyLayout?.cardRect ?? contentRect
        return AnnotationCameraGeometry(spec: camera, contentRect: cardRect)
    }

    /// Replaces the current camera, coalescing successive inspector edits into one undo
    /// step so dragging a slider does not flood the undo stack.
    mutating func setCamera(_ spec: AnnotationCameraSpec?) {
        var updated = commands
        updated.removeAll { command in
            if case .camera = command {
                return true
            }
            return false
        }
        if let spec, !spec.isIdentity {
            updated.insert(.camera(spec), at: 0)
        }
        guard updated != commands else { return }
        if shouldCoalesce(updated, matching: {
            if case .camera = $0 {
                true
            } else {
                false
            }
        }) {
            history[historyIndex] = updated
            return
        }
        pushHistory(updated)
    }

    /// The progressive blur in force, if any. The last one wins.
    var progressiveBlur: ProgressiveBlurSpec? {
        commands.reversed().compactMap { command in
            if case let .progressiveBlur(spec) = command {
                return spec
            }
            return nil
        }.first
    }

    /// Replaces the progressive blur, coalescing successive inspector edits into one undo
    /// step so dragging a slider does not flood the undo stack.
    mutating func setProgressiveBlur(_ spec: ProgressiveBlurSpec?) {
        var updated = commands
        updated.removeAll { command in
            if case .progressiveBlur = command {
                return true
            }
            return false
        }
        if let spec, !spec.isIdentity {
            updated.insert(.progressiveBlur(spec), at: 0)
        }
        guard updated != commands else { return }
        if shouldCoalesce(updated, matching: {
            if case .progressiveBlur = $0 {
                true
            } else {
                false
            }
        }) {
            history[historyIndex] = updated
            return
        }
        pushHistory(updated)
    }
}
