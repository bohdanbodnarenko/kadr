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
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)
    private let frontmostApplication: any FrontmostApplicationProviding
    private let ownBundleIdentifier: String?

    /// Whether captures keep the display's HDR range (docs/06 M25).
    ///
    /// State on the engine rather than a parameter on every capture call: it is a setting,
    /// it applies to all of them, and threading it through four signatures and their
    /// callers would only make each of those calls harder to read.
    public private(set) var dynamicRange: DynamicRange = .standard

    public func setDynamicRange(_ range: DynamicRange) {
        dynamicRange = range.resolved
    }

    public init(
        frontmostApplication: any FrontmostApplicationProviding = WorkspaceFrontmostApplication(),
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.frontmostApplication = frontmostApplication
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    // MARK: - Content

    /// The displays and windows currently available, as value types.
    public func shareableContent(onScreenWindowsOnly: Bool = true) async throws -> ShareableContentSnapshot {
        let content = try await content(onScreenWindowsOnly: onScreenWindowsOnly)
        return snapshot(of: content)
    }

    // MARK: - Freeze

    /// Captures every display at once, for the selection overlay to draw and crop from.
    ///
    /// The displays are captured concurrently in a task group because the budget is one
    /// freeze for *all* displays under 80 ms (docs/04 §4.2) — doing them in sequence
    /// spends that budget twice on a two-display desk.
    public func freezeAllDisplays(options: FreezeOptions = FreezeOptions()) async throws -> [DisplayFreeze] {
        let state = signposter.beginInterval("freezeAllDisplays")
        defer { signposter.endInterval("freezeAllDisplays", state) }

        let content = try await content(onScreenWindowsOnly: true)
        let excluded = options.excludesOwnWindows ? ownApplications(in: content) : []
        // Read once, off the actor, so the concurrent freezes agree with each other and
        // with the capture that is cropped out of them (docs/04 §4.2).
        let range = dynamicRange

        return try await withThrowingTaskGroup(of: DisplayFreeze.self) { group in
            for display in content.displays {
                let boxed = UncheckedSendableBox((display: display, excluded: excluded))
                group.addTask {
                    try await self.freeze(
                        display: boxed.value.display,
                        excluding: boxed.value.excluded,
                        options: options,
                        dynamicRange: range
                    )
                }
            }
            var freezes: [DisplayFreeze] = []
            freezes.reserveCapacity(content.displays.count)
            for try await freeze in group {
                freezes.append(freeze)
            }
            // Task groups finish out of order; keep displays in a stable order.
            return freezes.sorted { $0.geometry.displayID < $1.geometry.displayID }
        }
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

        let content = try await content(onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }

        let excluded = excludesOwnWindows ? ownApplications(in: content) : []
        let filter = excluded.isEmpty
            ? SCContentFilter(display: display, excludingWindows: [])
            : SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
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
    public func captureAllDisplays(
        includesCursor: Bool = false,
        excludesOwnWindows: Bool = true
    ) async throws -> [Capture] {
        let content = try await content(onScreenWindowsOnly: true)
        let displayIDs = content.displays.map(\.displayID)

        return try await withThrowingTaskGroup(of: Capture.self) { group in
            for displayID in displayIDs {
                group.addTask {
                    try await self.captureDisplay(
                        displayID,
                        includesCursor: includesCursor,
                        excludesOwnWindows: excludesOwnWindows
                    )
                }
            }
            var captures: [Capture] = []
            captures.reserveCapacity(displayIDs.count)
            for try await capture in group {
                captures.append(capture)
            }
            // Task groups finish out of order; keep displays in a stable order.
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
        includesCursor: Bool = false
    ) async throws -> Capture {
        let state = signposter.beginInterval("captureRegion")
        defer { signposter.endInterval("captureRegion", state) }

        guard !region.isEmpty else { throw CaptureError.emptyRegion }

        let content = try await content(onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
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

    private func content(onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: onScreenWindowsOnly
            )
        } catch {
            throw CaptureError.mapping(error)
        }
    }

    private nonisolated func freeze(
        display: SCDisplay,
        excluding applications: [SCRunningApplication],
        options: FreezeOptions,
        dynamicRange: DynamicRange = .standard
    ) async throws -> DisplayFreeze {
        let filter = if applications.isEmpty {
            SCContentFilter(display: display, excludingWindows: [])
        } else {
            SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: [])
        }
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = !options.excludesMenuBar
        }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = options.includesCursor
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

    private func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        guard let ownBundleIdentifier else { return [] }
        return content.applications.filter { $0.bundleIdentifier == ownBundleIdentifier }
    }

    /// The geometry half of a capture's metadata, grouped so the builder stays
    /// readable at its three call sites.
    struct CaptureOrigin {
        let source: CaptureSource
        let displayID: CGDirectDisplayID?
        let scale: DisplayScale
        let pointRect: DisplayRect
    }

    private nonisolated func metadata(
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

    private func snapshot(of content: SCShareableContent) -> ShareableContentSnapshot {
        let displays = content.displays.map { display in
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return DisplayGeometry(
                displayID: display.displayID,
                frame: DisplayRect(cgRect: display.frame),
                scale: DisplayScale(CGFloat(filter.pointPixelScale))
            )
        }
        let windows = content.windows.map { window in
            WindowInfo(
                id: window.windowID,
                title: window.title,
                applicationName: window.owningApplication?.applicationName,
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                processID: window.owningApplication?.processID ?? 0,
                frame: DisplayRect(cgRect: window.frame),
                isOnScreen: window.isOnScreen,
                layer: window.windowLayer
            )
        }
        return ShareableContentSnapshot(displays: displays, windows: windows)
    }
}
