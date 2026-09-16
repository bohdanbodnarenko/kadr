import AnnotationModel
import CoreGraphics
import Foundation
import os
import Shared

/// The pixels one editor canvas redacts, and every preview made from them (docs/10 R1).
///
/// Owns three things the canvas used to do on the main actor, per mouse-move:
///
/// * **The exact preview** of a box that has stopped moving, rendered off the main actor
///   and cached against this source's token. A newer request for the same annotation
///   cancels the older one, so a result for a box that has since moved never lands.
/// * **The gesture stand-in**, the style rendered over the whole capture once, so a box
///   being dragged only changes which part of it is shown (`RedactionGestureImage`).
/// * **Cleanup.** The previews live in a process-wide cache; releasing the source takes
///   its entries with it, which is what a closing window needs in an editor process that
///   may host several.
///
/// Called from the main actor; the renders run detached with value inputs only, and
/// report back through `onPreviewReady` on the main actor.
public final class RedactionPreviewSource: @unchecked Sendable {
    /// Identifies this source's entries in the shared cache.
    public let token = UUID()
    public let image: CGImage
    /// The capture's pixels per point.
    public let scale: CGFloat

    /// Run on the main actor whenever a render finishes, so the canvas can put it on
    /// screen. Set once by the canvas.
    @MainActor public var onPreviewReady: (() -> Void)?

    private let cache: RedactionPreviewCache
    private let rasterizer = RedactionRasterizer()
    private let signposter = KadrLog.signposter(.overlay)
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many whole-capture stand-ins are kept. Each is small (a blur is capped at
    /// 2048 px on its long edge, a mosaic is a cell per pixel), and a session rarely
    /// flips between more than two styles.
    static let gestureImageLimit = 2

    private struct State {
        var gestureImages: [RedactionStyle: RedactionGestureImage] = [:]
        var gestureOrder: [RedactionStyle] = []
        var gestureInFlight: Set<RedactionStyle> = []
        var exactInFlight: [AnnotationID: (key: RedactionPreviewCache.Key, task: Task<Void, Never>)] = [:]
    }

    public convenience init(image: CGImage, scale: CGFloat) {
        self.init(image: image, scale: scale, cache: .shared)
    }

    init(image: CGImage, scale: CGFloat, cache: RedactionPreviewCache) {
        self.image = image
        self.scale = scale
        self.cache = cache
    }

    deinit {
        let inFlight = state.withLock { $0.exactInFlight.values.map(\.task) }
        inFlight.forEach { $0.cancel() }
        cache.removeAll(token: token)
    }

    func key(for spec: RedactionSpec) -> RedactionPreviewCache.Key {
        RedactionPreviewCache.Key(token: token, spec: spec, scale: scale)
    }

    /// The exact preview, if it has been rendered.
    func cachedExact(_ spec: RedactionSpec) -> CGImage? {
        cache.image(for: key(for: spec))
    }

    /// Renders the exact preview on the calling thread and caches it.
    ///
    /// For a layer that has nothing on screen yet — opening a document — where a grey box
    /// followed by the real thing would read as a flicker.
    func renderExactNow(_ spec: RedactionSpec, caching: Bool = true) -> CGImage? {
        let interval = signposter.beginInterval("editor.redaction.preview", "exact, inline")
        defer { signposter.endInterval("editor.redaction.preview", interval) }
        guard let preview = rasterizer.preview(spec, from: image, scale: scale) else { return nil }
        if caching {
            cache.insert(preview, for: key(for: spec))
        }
        return preview
    }

    /// Starts the exact preview off the main actor, unless it is cached or already coming.
    func requestExact(_ spec: RedactionSpec) {
        let key = key(for: spec)
        guard cache.image(for: key) == nil else { return }
        let id = spec.id
        let (shouldStart, superseded) = state.withLock { state -> (Bool, Task<Void, Never>?) in
            if let current = state.exactInFlight[id] {
                guard current.key != key else { return (false, nil) }
                return (true, current.task)
            }
            return (true, nil)
        }
        superseded?.cancel()
        guard shouldStart else { return }

        let rasterizer = rasterizer
        let image = image
        let scale = scale
        let cache = cache
        let signposter = signposter
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let interval = signposter.beginInterval("editor.redaction.preview", "exact")
            let preview = rasterizer.preview(spec, from: image, scale: scale)
            signposter.endInterval("editor.redaction.preview", interval)
            guard !Task.isCancelled else { return }
            if let preview {
                cache.insert(preview, for: key)
            }
            self?.finishExact(id: id, key: key)
            await self?.notifyReady()
        }
        state.withLock { $0.exactInFlight[id] = (key, task) }
    }

    private func finishExact(id: AnnotationID, key: RedactionPreviewCache.Key) {
        state.withLock { state in
            if state.exactInFlight[id]?.key == key {
                state.exactInFlight[id] = nil
            }
        }
    }

    /// The whole-capture stand-in for `style`, or nil while it is being made — in which
    /// case this starts making it.
    func gestureImage(for style: RedactionStyle) -> RedactionGestureImage? {
        if case .erase = style {
            return nil
        }
        let (ready, shouldStart) = state.withLock { state -> (RedactionGestureImage?, Bool) in
            if let ready = state.gestureImages[style] {
                return (ready, false)
            }
            guard !state.gestureInFlight.contains(style) else { return (nil, false) }
            state.gestureInFlight.insert(style)
            return (nil, true)
        }
        if let ready {
            return ready
        }
        if shouldStart {
            startGestureImage(for: style)
        }
        return nil
    }

    /// Whether a stand-in for `style` is ready right now. Does not start one.
    func hasGestureImage(for style: RedactionStyle) -> Bool {
        state.withLock { $0.gestureImages[style] != nil }
    }

    private func startGestureImage(for style: RedactionStyle) {
        let rasterizer = rasterizer
        let image = image
        let signposter = signposter
        Task.detached(priority: .userInitiated) { [weak self] in
            let interval = signposter.beginInterval("editor.redaction.preview", "gesture stand-in")
            let rendered = rasterizer.gestureImage(for: style, from: image)
            signposter.endInterval("editor.redaction.preview", interval)
            self?.storeGestureImage(rendered, for: style)
            await self?.notifyReady()
        }
    }

    private func storeGestureImage(_ rendered: RedactionGestureImage?, for style: RedactionStyle) {
        state.withLock { state in
            state.gestureInFlight.remove(style)
            guard let rendered else { return }
            state.gestureImages[style] = rendered
            state.gestureOrder.removeAll { $0 == style }
            state.gestureOrder.append(style)
            while state.gestureOrder.count > Self.gestureImageLimit {
                let oldest = state.gestureOrder.removeFirst()
                state.gestureImages[oldest] = nil
            }
        }
    }

    private func notifyReady() async {
        await MainActor.run {
            onPreviewReady?()
        }
    }
}
