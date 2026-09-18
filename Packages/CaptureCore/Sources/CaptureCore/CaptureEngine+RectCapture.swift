import CoreGraphics
import Foundation
import ScreenCaptureKit
import Shared

/// Still capture that never asks ScreenCaptureKit for the window list (docs/04 §4.1).
///
/// `SCShareableContent.excludingDesktopWindows` is what presents the macOS 15+
/// "record this computer's screen and audio" sheet — and it can re-present on every
/// call even when Screen Recording is already on in Settings. A tool that shells out to
/// `/usr/sbin/screencapture` never touches it. Kadr still has to produce
/// an in-process `CGImage` for the freeze overlay, so the equivalent is
/// `SCScreenshotManager.captureImage(in:)`, which captures a display-space rect
/// without enumerating windows.
///
/// Overlay panels set `sharingType = .none`, so they stay out of these captures the
/// same way `excludingWindows` used to keep them out of a display filter.
///
/// Window capture and recording still go through shareable content: they need an
/// `SCWindow` / `SCStream` filter. macOS 14 has no rect-capture API, so it keeps
/// the filter path.
extension CaptureEngine {
    var prefersDirectRectCapture: Bool {
        if #available(macOS 15.2, *) {
            return true
        }
        return false
    }

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return Array(ids.prefix(Int(count)))
    }

    static func geometry(of displayID: CGDirectDisplayID) -> DisplayGeometry {
        let bounds = CGDisplayBounds(displayID)
        let pixels = CGFloat(CGDisplayPixelsWide(displayID))
        let scale = bounds.width > 0 ? pixels / bounds.width : 1
        return DisplayGeometry(
            displayID: displayID,
            frame: DisplayRect(cgRect: bounds),
            scale: DisplayScale(max(scale, 1))
        )
    }

    func freezeAllDisplaysDirectly(options: FreezeOptions) async throws -> [DisplayFreeze] {
        let ids = Self.activeDisplayIDs()
        guard !ids.isEmpty else { throw CaptureError.noCaptureSource }
        let range = dynamicRange
        return try await withThrowingTaskGroup(of: DisplayFreeze.self) { group in
            for displayID in ids {
                group.addTask {
                    try await self.freezeDisplay(
                        displayID,
                        includesCursor: options.includesCursor,
                        dynamicRange: range
                    )
                }
            }
            var freezes: [DisplayFreeze] = []
            freezes.reserveCapacity(ids.count)
            for try await freeze in group {
                freezes.append(freeze)
            }
            return freezes.sorted { $0.geometry.displayID < $1.geometry.displayID }
        }
    }

    func captureDisplaysDirectly(
        includesCursor: Bool,
        frontmostApp: AppIdentity?
    ) async throws -> [Capture] {
        let ids = Self.activeDisplayIDs()
        guard !ids.isEmpty else { throw CaptureError.noCaptureSource }
        let range = dynamicRange
        return try await withThrowingTaskGroup(of: Capture.self) { group in
            for displayID in ids {
                group.addTask {
                    try await self.captureDisplayDirectly(
                        displayID,
                        includesCursor: includesCursor,
                        dynamicRange: range,
                        frontmostApp: frontmostApp
                    )
                }
            }
            var captures: [Capture] = []
            captures.reserveCapacity(ids.count)
            for try await capture in group {
                captures.append(capture)
            }
            return captures.sorted { ($0.metadata.displayID ?? 0) < ($1.metadata.displayID ?? 0) }
        }
    }

    nonisolated func freezeDisplay(
        _ displayID: CGDirectDisplayID,
        includesCursor: Bool,
        dynamicRange: DynamicRange
    ) async throws -> DisplayFreeze {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else {
            throw CaptureError.displayNotFound(displayID)
        }
        let image = try await screenshot(
            rect: bounds,
            includesCursor: includesCursor,
            dynamicRange: dynamicRange
        )
        let scale = bounds.width > 0
            ? DisplayScale(CGFloat(image.width) / bounds.width)
            : .oneToOne
        return DisplayFreeze(
            geometry: DisplayGeometry(
                displayID: displayID,
                frame: DisplayRect(cgRect: bounds),
                scale: scale
            ),
            image: image
        )
    }

    nonisolated func captureDisplayDirectly(
        _ displayID: CGDirectDisplayID,
        includesCursor: Bool,
        dynamicRange: DynamicRange,
        frontmostApp: AppIdentity?
    ) async throws -> Capture {
        let freeze = try await freezeDisplay(
            displayID,
            includesCursor: includesCursor,
            dynamicRange: dynamicRange
        )
        return Capture(
            image: freeze.image,
            metadata: metadata(
                origin: CaptureOrigin(
                    source: .display(displayID),
                    displayID: displayID,
                    scale: freeze.geometry.scale,
                    pointRect: freeze.geometry.frame
                ),
                image: freeze.image,
                frontmostApp: frontmostApp
            )
        )
    }

    func captureRegionDirectly(
        _ region: DisplayRect,
        on displayID: CGDirectDisplayID,
        includesCursor: Bool,
        frontmostApp: AppIdentity?
    ) async throws -> Capture {
        let geometry = Self.geometry(of: displayID)
        guard let clamped = geometry.clamped(region) else {
            throw CaptureError.regionOutsideDisplay
        }
        guard !clamped.isEmpty else { throw CaptureError.emptyRegion }
        let image = try await screenshot(
            rect: clamped.cgRect,
            includesCursor: includesCursor,
            dynamicRange: dynamicRange
        )
        let scale = clamped.width > 0
            ? DisplayScale(CGFloat(image.width) / clamped.width)
            : geometry.scale
        return Capture(
            image: image,
            metadata: metadata(
                origin: CaptureOrigin(
                    source: .region(display: displayID),
                    displayID: displayID,
                    scale: scale,
                    pointRect: clamped
                ),
                image: image,
                frontmostApp: frontmostApp
            )
        )
    }

    /// Pixels of a display-space rect, without asking for the window list.
    nonisolated func screenshot(
        rect: CGRect,
        includesCursor: Bool,
        dynamicRange: DynamicRange
    ) async throws -> CGImage {
        do {
            if #available(macOS 26.0, *) {
                let configuration = SCScreenshotConfiguration()
                configuration.showsCursor = includesCursor
                configuration.dynamicRange = dynamicRange.isHigh ? .hdr : .sdr
                let output = try await SCScreenshotManager.captureScreenshot(
                    rect: rect,
                    configuration: configuration
                )
                if dynamicRange.isHigh, let hdr = output.hdrImage {
                    return hdr
                }
                if let sdr = output.sdrImage {
                    return sdr
                }
                throw CaptureError.captureFailed(code: -1, description: "macOS returned no screenshot.")
            }
            if #available(macOS 15.2, *) {
                return try await SCScreenshotManager.captureImage(in: rect)
            }
            throw CaptureError.captureFailed(
                code: -1,
                description: "Direct screenshot requires macOS 15.2 or later."
            )
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.mapping(error)
        }
    }
}
