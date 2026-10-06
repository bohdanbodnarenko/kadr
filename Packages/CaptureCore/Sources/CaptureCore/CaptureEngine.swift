import CoreGraphics
import Foundation
import os
import ScreenCaptureKit
import Shared

/// Every still capture in Kadr (docs/04 §4.2).
///
/// An actor because the SCK objects it holds are reference types that are not
/// `Sendable`: `SCDisplay`, `SCWindow` and `SCContentFilter` never leave this isolation
/// domain, and callers exchange value types (`ShareableContentSnapshot`, `Capture`)
/// instead.
///
/// Two rules from the architecture hold everywhere in here:
///
/// * `SCScreenshotManager` only — never `CGWindowListCreateImage` or
///   `CGDisplayCreateImage`. The legacy path is deprecated and triggers extra TCC
///   alerts on Sonoma and later (docs/04 §12), and `Scripts/check-layering.sh` fails
///   the build if it ever reappears.
/// * All SCK calls stay in the agent process so the Screen Recording grant attaches to
///   the app the user actually sees (docs/04 §1).
public actor CaptureEngine {
    let logger = KadrLog.logger(.capture)
    let signposter = KadrLog.signposter(.capture)
    private let frontmostApplication: any FrontmostApplicationProviding

    /// Whether captures keep the display's HDR range (docs/06 M25).
    ///
    /// State on the engine rather than a parameter on every capture call: it is a setting,
    /// it applies to all of them, and threading it through four signatures and their
    /// callers would only make each of those calls harder to read.
    public private(set) var dynamicRange: DynamicRange = .standard

    /// Window numbers to leave out of display and region captures (docs/10 R3.2).
    ///
    /// Per-window rather than the whole app: overlays register themselves, Settings does
    /// not, and a bug report can include a screenshot of the Settings window. Empty means
    /// exclude nothing. The agent pushes the registry here before each freeze or capture
    /// because OverlayKit cannot import this package.
    public private(set) var excludedWindowIDs: Set<CGWindowID> = []

    public func setDynamicRange(_ range: DynamicRange) {
        dynamicRange = range.resolved
    }

    public func setExcludedWindowIDs(_ ids: Set<CGWindowID>) {
        excludedWindowIDs = ids
    }

    public init(
        frontmostApplication: any FrontmostApplicationProviding = WorkspaceFrontmostApplication()
    ) {
        self.frontmostApplication = frontmostApplication
    }

    // MARK: - Content

    /// The displays and windows currently available, as value types.
    public func shareableContent(onScreenWindowsOnly: Bool = true) async throws -> ShareableContentSnapshot {
        let content = try await content(onScreenWindowsOnly: onScreenWindowsOnly)
        return snapshot(of: content)
    }

    // MARK: - Captures

    /// Captures a whole display (docs/03 §1.3).
    public func captureDisplay(
        _ displayID: CGDirectDisplayID,
        includesCursor: Bool = false,
        excludesOwnWindows: Bool = true
    ) async throws -> Capture {
        let state = signposter.beginInterval("captureDisplay")
        defer { signposter.endInterval("captureDisplay", state) }

        if prefersDirectRectCapture(includesCursor: includesCursor) {
            let frontmost = await frontmostApplication.currentApplication()
            return try await captureDisplayDirectly(
                displayID,
                includesCursor: includesCursor,
                dynamicRange: dynamicRange,
                frontmostApp: frontmost
            )
        }

        let content = try await content(onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }

        let filter = Self.filter(
            for: display,
            excluding: excludesOwnWindows ? Self.windows(matching: excludedWindowIDs, in: content) : []
        )
        let scale = DisplayScale(CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = includesCursor
        apply(size: filter.contentRect.size, scale: filter.pointPixelScale, to: configuration)
        applyDynamicRange(dynamicRange, to: configuration)

        let image = try await screenshot(ScreenshotRequest(filter: filter, configuration: configuration))
        return await Capture(
            image: image,
            metadata: metadata(
                origin: CaptureOrigin(
                    source: .display(displayID),
                    displayID: displayID,
                    scale: scale,
                    pointRect: DisplayRect(cgRect: display.frame)
                ),
                image: image,
                frontmostApp: frontmostApplication.currentApplication()
            )
        )
    }

    /// Captures every display at once (docs/03 §1.3).
    ///
    /// Concurrent for the same reason the freeze is: the displays should show the same
    /// instant, and a serial loop makes the second monitor lag the first by a frame or
    /// more of real time.
    ///
    /// Shareable content is fetched once. Calling `SCShareableContent` per display
    /// re-presents the macOS 15+ consent sheet on every monitor, even when Screen
    /// Recording is already granted (docs/04 §4.1).
    public func captureAllDisplays(
        includesCursor: Bool = false,
        excludesOwnWindows: Bool = true
    ) async throws -> [Capture] {
        if prefersDirectRectCapture(includesCursor: includesCursor) {
            let frontmost = await frontmostApplication.currentApplication()
            return try await captureDisplaysDirectly(
                includesCursor: includesCursor,
                frontmostApp: frontmost
            )
        }

        let content = try await content(onScreenWindowsOnly: true)
        let excluded = excludesOwnWindows ? Self.windows(matching: excludedWindowIDs, in: content) : []
        let cursor = includesCursor
        let range = dynamicRange
        let frontmost = await frontmostApplication.currentApplication()

        return try await withThrowingTaskGroup(of: Capture.self) { group in
            for display in content.displays {
                let boxed = UncheckedSendableBox((display: display, excluded: excluded))
                group.addTask {
                    try await self.capture(
                        display: boxed.value.display,
                        excluding: boxed.value.excluded,
                        includesCursor: cursor,
                        dynamicRange: range,
                        frontmostApp: frontmost
                    )
                }
            }
            var captures: [Capture] = []
            captures.reserveCapacity(content.displays.count)
            for try await capture in group {
                captures.append(capture)
            }
            return captures.sorted { ($0.metadata.displayID ?? 0) < ($1.metadata.displayID ?? 0) }
        }
    }

    /// Captures a region of one display (docs/03 §1.1).
    ///
    /// `region` is in global display space; it is rebased onto the display and scaled to
    /// its backing store here, which is the one place that conversion happens.
    public func captureRegion(
        _ region: DisplayRect,
        on displayID: CGDirectDisplayID,
        includesCursor: Bool = false,
        excludesOwnWindows: Bool = true
    ) async throws -> Capture {
        let state = signposter.beginInterval("captureRegion")
        defer { signposter.endInterval("captureRegion", state) }

        guard !region.isEmpty else { throw CaptureError.emptyRegion }

        if prefersDirectRectCapture(includesCursor: includesCursor) {
            let frontmost = await frontmostApplication.currentApplication()
            return try await captureRegionDirectly(
                region,
                on: displayID,
                includesCursor: includesCursor,
                frontmostApp: frontmost
            )
        }

        let content = try await content(onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }

        // Kadr's own windows are excluded here too, not just in the full-display paths: a
        // card or a pin sitting over the region the user selected ends up in the file
        // otherwise (docs/07 LOW).
        let filter = Self.filter(
            for: display,
            excluding: excludesOwnWindows ? Self.windows(matching: excludedWindowIDs, in: content) : []
        )
        let geometry = DisplayGeometry(
            displayID: displayID,
            frame: DisplayRect(cgRect: display.frame),
            scale: DisplayScale(CGFloat(filter.pointPixelScale))
        )
        guard let clamped = geometry.clamped(region) else { throw CaptureError.regionOutsideDisplay }

        let local = geometry.localRect(for: clamped)
        let pixels = geometry.pixels(for: local)
        guard !pixels.isEmpty else { throw CaptureError.emptyRegion }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = includesCursor
        configuration.sourceRect = local.cgRect
        configuration.width = pixels.width
        configuration.height = pixels.height
        applyDynamicRange(dynamicRange, to: configuration)

        let image = try await screenshot(ScreenshotRequest(filter: filter, configuration: configuration))
        return await Capture(
            image: image,
            metadata: metadata(
                origin: CaptureOrigin(
                    source: .region(display: displayID),
                    displayID: displayID,
                    scale: geometry.scale,
                    pointRect: clamped
                ),
                image: image,
                frontmostApp: frontmostApplication.currentApplication()
            )
        )
    }

    /// Captures one window unoccluded, at full backing resolution (docs/03 §1.2).
    ///
    /// The desktop-independent filter is what makes an overlapped window come out clean:
    /// SCK renders the window on its own rather than reading it out of the screen.
    public func captureWindow(
        _ windowID: CGWindowID,
        options: WindowCaptureOptions = WindowCaptureOptions()
    ) async throws -> Capture {
        let state = signposter.beginInterval("captureWindow")
        defer { signposter.endInterval("captureWindow", state) }

        let content = try await content(onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = options.includesCursor
        configuration.ignoreShadowsSingleWindow = !options.includesShadow
        configuration.shouldBeOpaque = !options.transparentBackground
        if options.transparentBackground {
            configuration.backgroundColor = .clear
        }
        if #available(macOS 14.2, *) {
            configuration.includeChildWindows = options.includesChildWindows
        }
        apply(size: filter.contentRect.size, scale: filter.pointPixelScale, to: configuration)
        applyDynamicRange(dynamicRange, to: configuration)

        let scale = DisplayScale(CGFloat(filter.pointPixelScale))
        let frame = DisplayRect(cgRect: window.frame)
        let title = window.title
        let owner = AppIdentity(
            name: window.owningApplication?.applicationName,
            bundleIdentifier: window.owningApplication?.bundleIdentifier
        )
        let image = try await screenshot(ScreenshotRequest(filter: filter, configuration: configuration))
        return Capture(
            image: image,
            metadata: metadata(
                origin: CaptureOrigin(
                    source: .window(windowID),
                    displayID: nil,
                    scale: scale,
                    pointRect: frame
                ),
                image: image,
                frontmostApp: owner,
                windowTitle: title
            )
        )
    }

    // MARK: - Internals

    func content(onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: onScreenWindowsOnly
            )
        } catch {
            throw CaptureError.mapping(error)
        }
    }

    nonisolated func freeze(
        display: SCDisplay,
        excluding windows: [SCWindow],
        options: FreezeOptions,
        dynamicRange: DynamicRange = .standard
    ) async throws -> DisplayFreeze {
        let filter = Self.filter(for: display, excluding: windows)
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = !options.excludesMenuBar
        }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = options.includesCursor
        configuration.ignoreShadowsDisplay = false
        apply(size: filter.contentRect.size, scale: filter.pointPixelScale, to: configuration)
        // The freeze is what an area capture is cropped out of, so it has to be captured
        // in the same range as the file the user will get — otherwise "what you selected
        // is what you get" would quietly stop being true for HDR (docs/04 §4.2).
        applyDynamicRange(dynamicRange, to: configuration)

        let geometry = DisplayGeometry(
            displayID: display.displayID,
            frame: DisplayRect(cgRect: display.frame),
            scale: DisplayScale(CGFloat(filter.pointPixelScale))
        )
        let image = try await screenshot(ScreenshotRequest(filter: filter, configuration: configuration))
        return DisplayFreeze(geometry: geometry, image: image)
    }

    /// One display, already resolved out of shareable content, so a multi-display
    /// capture does not ask ScreenCaptureKit for the window list again.
    private nonisolated func capture(
        display: SCDisplay,
        excluding windows: [SCWindow],
        includesCursor: Bool,
        dynamicRange: DynamicRange,
        frontmostApp: AppIdentity?
    ) async throws -> Capture {
        let filter = Self.filter(for: display, excluding: windows)
        let scale = DisplayScale(CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = includesCursor
        configuration.ignoreShadowsDisplay = false
        apply(size: filter.contentRect.size, scale: filter.pointPixelScale, to: configuration)
        applyDynamicRange(dynamicRange, to: configuration)

        let image = try await screenshot(ScreenshotRequest(filter: filter, configuration: configuration))
        return Capture(
            image: image,
            metadata: metadata(
                origin: CaptureOrigin(
                    source: .display(display.displayID),
                    displayID: display.displayID,
                    scale: scale,
                    pointRect: DisplayRect(cgRect: display.frame)
                ),
                image: image,
                frontmostApp: frontmostApp
            )
        )
    }

    /// The one call into ScreenCaptureKit that produces pixels.
    private nonisolated func screenshot(_ request: ScreenshotRequest) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: request.filter,
                configuration: request.configuration
            )
        } catch {
            let mapped = CaptureError.mapping(error)
            logger.error("Capture failed: \(String(describing: mapped), privacy: .public)")
            throw mapped
        }
    }

    /// Sets the output size to the source's real backing-store size.
    ///
    /// `pointPixelScale` is SCK's own opinion of the display's scale factor, which is
    /// the number that makes a Retina capture come out sharp instead of half-size.
    private nonisolated func apply(size: CGSize, scale: Float, to configuration: SCStreamConfiguration) {
        configuration.width = Int((size.width * CGFloat(scale)).rounded())
        configuration.height = Int((size.height * CGFloat(scale)).rounded())
        // Explicit on macOS 14.0–15.1 so overlapping windows keep their drop shadows
        // (docs/16 CAP-11).
        configuration.ignoreShadowsDisplay = false
    }

    /// Asks ScreenCaptureKit for the display's full range, when the user wants it and the
    /// system can do it (docs/04 §4.1, docs/06 M25).
    ///
    /// `hdrLocalDisplay` rather than `hdrCanonicalDisplay`: the local variant matches what
    /// this display is actually showing, which is the promise a screenshot makes. The
    /// canonical one is for content that has to look the same on someone else's screen,
    /// which is a video-production concern rather than a screenshot one.
    private nonisolated func applyDynamicRange(_ range: DynamicRange, to configuration: SCStreamConfiguration) {
        guard range.resolved.isHigh else { return }
        if #available(macOS 15.0, *) {
            configuration.captureDynamicRange = .hdrLocalDisplay
        }
    }

    /// The geometry half of a capture's metadata, grouped so the builder stays
    /// readable at its three call sites.
    struct CaptureOrigin {
        let source: CaptureSource
        let displayID: CGDirectDisplayID?
        let scale: DisplayScale
        let pointRect: DisplayRect
    }

    nonisolated func metadata(
        origin: CaptureOrigin,
        image: CGImage,
        frontmostApp: AppIdentity?,
        windowTitle: String? = nil
    ) -> CaptureMetadata {
        CaptureMetadata(
            source: origin.source,
            displayID: origin.displayID,
            scale: origin.scale,
            pointRect: origin.pointRect,
            pixelSize: PixelSize(width: image.width, height: image.height),
            colorSpaceName: image.colorSpace?.name as String?,
            frontmostApp: frontmostApp,
            windowTitle: windowTitle
        )
    }

    /// A display filter with specific windows left out of it (docs/10 R3.2).
    ///
    /// Always `excludingWindows`, never the whole application: overlays belong on the
    /// list, Settings does not, and whole-app exclusion made Kadr's own windows
    /// un-screenshotable.
    nonisolated static func filter(
        for display: SCDisplay,
        excluding windows: [SCWindow]
    ) -> SCContentFilter {
        SCContentFilter(display: display, excludingWindows: windows)
    }

    /// The shareable windows whose IDs are currently registered for exclusion.
    nonisolated static func windows(
        matching ids: Set<CGWindowID>,
        in content: SCShareableContent
    ) -> [SCWindow] {
        guard !ids.isEmpty else { return [] }
        return content.windows.filter { ids.contains($0.windowID) }
    }
}
