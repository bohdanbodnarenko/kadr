import Foundation
import ScreenCaptureKit

/// Everything the capture layer can fail with, mapped off ScreenCaptureKit's
/// `SCStreamErrorDomain` codes (docs/04 §4.1).
///
/// The mapping matters for one reason above all: telling "the user revoked Screen
/// Recording" apart from "that window went away". The first has to surface a re-grant
/// sheet, the second is a shrug.
public enum CaptureError: Error, Equatable, Sendable {
    /// The Screen Recording grant is missing or has been withdrawn.
    case permissionDenied
    /// SCK refused for entitlement reasons — in practice this also means no grant.
    case missingEntitlements
    /// SCK has no display or window list to work from.
    case noCaptureSource
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(CGWindowID)
    /// The requested region does not overlap the display it was asked for.
    case regionOutsideDisplay
    /// A region or window with no area.
    case emptyRegion
    /// SCK returned an error we do not special-case.
    case captureFailed(code: Int, description: String)

    /// Maps any error thrown by ScreenCaptureKit into this vocabulary.
    public static func mapping(_ error: any Error) -> CaptureError {
        if let captureError = error as? CaptureError {
            return captureError
        }

        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else {
            return .captureFailed(code: nsError.code, description: nsError.localizedDescription)
        }

        switch nsError.code {
        case SCStreamError.Code.userDeclined.rawValue:
            return .permissionDenied
        case SCStreamError.Code.missingEntitlements.rawValue:
            return .missingEntitlements
        case SCStreamError.Code.noCaptureSource.rawValue,
             SCStreamError.Code.noDisplayList.rawValue,
             SCStreamError.Code.noWindowList.rawValue:
            return .noCaptureSource
        default:
            return .captureFailed(code: nsError.code, description: nsError.localizedDescription)
        }
    }

    /// Whether this error means the TCC grant is gone and the user must re-approve.
    ///
    /// macOS 15 asks the user to re-confirm screen recording roughly monthly; when they
    /// let it lapse, SCK reports it as a declined capture rather than a distinct code
    /// (docs/04 §4.1), so this is how revocation is detected in practice.
    public var indicatesPermissionLoss: Bool {
        switch self {
        case .permissionDenied, .missingEntitlements: true
        case .noCaptureSource, .displayNotFound, .windowNotFound,
             .regionOutsideDisplay, .emptyRegion, .captureFailed: false
        }
    }
}

extension CaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Kadr does not have permission to record the screen."
        case .missingEntitlements:
            "macOS refused the capture because Kadr is missing an entitlement."
        case .noCaptureSource:
            "macOS reported no displays or windows available to capture."
        case let .displayNotFound(id):
            "Display \(id) is no longer connected."
        case let .windowNotFound(id):
            "Window \(id) is no longer on screen."
        case .regionOutsideDisplay:
            "That region is not on the display it was captured from."
        case .emptyRegion:
            "That selection has no area."
        case let .captureFailed(code, description):
            "Screen capture failed (\(code)): \(description)"
        }
    }
}
