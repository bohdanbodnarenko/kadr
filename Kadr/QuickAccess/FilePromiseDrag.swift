import AppKit
import os
import Shared
import SwiftUI
import UniformTypeIdentifiers

/// What a promise drag needs to know about the thing being dragged (docs/03 §2, §6).
///
/// The point of the indirection is `resolve`: it is called when the receiving app asks
/// for the bytes, not when the drag starts. A staged capture is finalised inside it, so
/// the URL handed over is the one the file actually has — the bug that made every drag
/// from a default-settings card deliver nothing (docs/07 C1).
struct FilePromisePayload: Sendable {
    /// The name the receiver should give the file, including its extension.
    var suggestedName: String
    var contentType: UTType
    /// Resolves — and if necessary finalises — the file to hand over. Main actor, called
    /// once per drop, never on drag start.
    var resolve: @MainActor @Sendable () -> URL?
    /// The drag ended. `true` when a receiver actually took the file, `false` when the
    /// user let go over nothing or pressed Escape.
    var completed: @MainActor @Sendable (Bool) -> Void
    /// Already-final path, for the `.fileURL` pasteboard flavour (docs/16 OUT-6).
    var stableFileURL: URL?
    /// A receiver read `stableFileURL` itself rather than claiming the promise, so it may
    /// keep that path (docs/18 OUT-2). Called on the main actor, before `completed`.
    var pathHandedOut: @MainActor @Sendable () -> Void

    init(
        suggestedName: String,
        contentType: UTType,
        resolve: @escaping @MainActor @Sendable () -> URL?,
        completed: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
        stableFileURL: URL? = nil,
        pathHandedOut: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.suggestedName = suggestedName
        self.contentType = contentType
        self.resolve = resolve
        self.completed = completed
        self.stableFileURL = stableFileURL
        self.pathHandedOut = pathHandedOut
    }

    /// The payload for a file that is already where it belongs and needs no finalising.
    static func file(
        at url: URL,
        completed: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
    ) -> FilePromisePayload {
        FilePromisePayload(
            suggestedName: url.lastPathComponent,
            contentType: UTType(filenameExtension: url.pathExtension) ?? .data,
            resolve: { url },
            completed: completed,
            stableFileURL: url
        )
    }
}

/// Runs one file-promise drag (docs/03 §2, §6; docs/04 §5).
///
/// Promises are what the docs specify, and they are the only thing that works for a
/// capture living in the staging area: the receiving app names a destination, we write
/// there, and nothing has to exist at a stable path beforehand. An `NSItemProvider` built
/// from a URL cannot express that — it captures a path at drag start, which is exactly how
/// a finalise-then-drag ordering bug becomes an empty drop (docs/07 C1).
///
/// A class rather than a protocol extension because AppKit needs a stable object to be the
/// dragging source for the session's lifetime — and because both the SwiftUI cards and the
/// AppKit pin windows need the same behaviour.
///
/// It is deliberately *not* the promise delegate. The receiver asks for the bytes after the
/// drop, which is after the session has ended and — with dismiss-on-drag — after the card
/// that owned this controller has been torn down. `NSFilePromiseProvider.delegate` is a weak
/// reference, so a delegate that lives on the card is nil exactly when it matters and the
/// drop delivers nothing (docs/07 C1). The delegate lives on the provider instead, which the
/// pasteboard keeps alive for as long as the promise can still be claimed.
@MainActor
final class FilePromiseDragController: NSObject, NSDraggingSource {
    /// The sources of the sessions in flight. `beginDraggingSession` does not retain its
    /// source, and the card can go away mid-drag, which would lose `completed` — the call
    /// that dismisses a dropped card. Always emptied by `endedAt`, which AppKit guarantees.
    private static var activeSources: [FilePromiseDragController] = []

    /// The payload for the drag in flight, kept only to report the outcome.
    private var inFlight: FilePromisePayload?

    /// Starts a promise drag from `view`, using `event` as the drag's origin.
    ///
    /// - Parameter companions: further files carried in the same drag, as Finder does with
    ///   a multiple selection (docs/18 OUT-8). Only `payload` reports the outcome.
    func beginDrag(
        from view: NSView,
        event: NSEvent,
        payload: FilePromisePayload,
        image: NSImage?,
        companions: [FilePromisePayload] = []
    ) {
        inFlight = payload
        Self.activeSources.append(self)

        let size = image?.size ?? CGSize(width: 64, height: 64)
        let frame = view.bounds.centred(size)
        let lead = NSDraggingItem(pasteboardWriter: KadrFilePromiseProvider(payload: payload))
        lead.setDraggingFrame(frame, contents: image)
        let companionItems = companions.enumerated().map { index, companion in
            let item = NSDraggingItem(pasteboardWriter: KadrFilePromiseProvider(payload: companion))
            // Fanned out behind the lead so the drag reads as a stack; AppKit badges the count.
            let offset = CGFloat(min(index + 1, 4)) * 4
            item.setDraggingFrame(frame.offsetBy(dx: offset, dy: -offset), contents: image)
            return item
        }

        view.beginDraggingSession(with: [lead] + companionItems, event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let payload = inFlight
        inFlight = nil
        Self.activeSources.removeAll { $0 === self }
        // `.none` is the user letting go over nothing, or pressing Escape. Anything else
        // means a receiver took it — the only moment a card may be dismissed (U0.1).
        payload?.completed(!operation.isEmpty)
    }
}

/// Fulfils one promise, on whatever thread AppKit asks from.
///
/// `nonisolated` on purpose: `writePromiseTo` is called on the queue `operationQueue(for:)`
/// hands back, not on the main thread, so a main-actor delegate would be a concurrency
/// violation on the app's hottest sharing path.
final nonisolated class FilePromiseFulfiller: NSObject, NSFilePromiseProviderDelegate {
    private let logger = KadrLog.logger(.overlay)
    private let payload: FilePromisePayload

    /// `NSFilePromiseProvider` writes on a queue we supply and blocks it until the
    /// completion handler fires. It cannot be the main queue — a large recording would
    /// freeze the UI for the length of the copy — so this is one of the API-required
    /// queues CLAUDE.md rule 5 allows, and it does nothing else.
    private let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.kadr.filePromise"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(payload: FilePromisePayload) {
        self.payload = payload
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        payload.suggestedName
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }

    /// The receiver has chosen a destination and wants the bytes.
    ///
    /// This is the only place a staged capture is finalised: a drag the user abandons
    /// never gets here, so the card and the staging area are left exactly as they were.
    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo destination: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // AppKit's completion handler predates `Sendable` and is called exactly once, from
        // wherever the copy finishes.
        nonisolated(unsafe) let finish = completionHandler
        Task { [payload, logger] in
            guard let source = await MainActor.run(body: { payload.resolve() }) else {
                logger.error("A promised drag had no file to hand over")
                finish(CocoaError(.fileNoSuchFile))
                return
            }
            do {
                // Off the main actor: a recording can be hundreds of megabytes, and the
                // receiving app is waiting on this copy.
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }.value
                finish(nil)
            } catch {
                logger.error("Promised drag failed: \(error.localizedDescription, privacy: .public)")
                finish(error)
            }
        }
    }
}

/// A SwiftUI drag source that hands over a file promise.
///
/// The view owns the whole mouse interaction — click, double-click and drag — because
/// When a press and a wobble is a drag, and when it is still a click.
///
/// One view owns click, double-click and drag, so this decides between them.
///
/// The threshold used to be 3 points, which is smaller than the wobble in an ordinary
/// double-click. So the first click of a double-click started a drag: the card lifted, the
/// user released without a drop, macOS played its snap-back animation — and because starting
/// the drag cleared the pending press, the double-click never arrived. Double-clicking a card
/// did not open the editor at all, it just made the card jump.
enum CardDragGesture {
    /// Below this a press and a move is still a click.
    ///
    /// Ten points rather than three: the number has to be larger than a hand holding still
    /// through two clicks, not merely larger than zero.
    static let dragThreshold: CGFloat = 10

    static func shouldBeginDrag(travelled: CGFloat, clickCount: Int) -> Bool {
        // Nothing that begins as the second click of a double-click is a drag, however far
        // the pointer then travels.
        guard clickCount < 2 else { return false }
        return travelled >= dragThreshold
    }
}

/// splitting them between SwiftUI gestures and an AppKit drag source is what makes drags
/// start when the user meant to click.
struct FilePromiseDragView: NSViewRepresentable {
    /// Built at drag time, so it always reflects the item's current state.
    var payload: @MainActor () -> FilePromisePayload
    /// A snapshot to drag under the pointer. Nil drags a generic icon.
    var dragImage: @MainActor () -> NSImage?
    var onTap: @MainActor () -> Void = {}
    var onDoubleTap: @MainActor () -> Void = {}
    /// Fired when the drag threshold is crossed, so auto-dismiss can pause.
    var onDragBegan: @MainActor () -> Void = {}
    /// Other files that travel with this one, such as the rest of a History selection.
    var companions: @MainActor () -> [FilePromisePayload] = { [] }

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        context.coordinator.owner = self
        view.coordinator = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    @MainActor
    final class Coordinator {
        var owner: FilePromiseDragView
        let dragController = FilePromiseDragController()

        init(owner: FilePromiseDragView) {
            self.owner = owner
        }

        func beginDrag(from view: NSView, event: NSEvent) {
            owner.onDragBegan()
            dragController.beginDrag(
                from: view,
                event: event,
                payload: owner.payload(),
                image: owner.dragImage(),
                companions: owner.companions()
            )
        }
    }

    /// The `NSView` that owns the mouse: clicks, double-clicks and the drag threshold.
    final class DragSourceView: NSView {
        var coordinator: Coordinator?
        private var mouseDownEvent: NSEvent?

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownEvent else { return }
            let travelled = hypot(
                event.locationInWindow.x - start.locationInWindow.x,
                event.locationInWindow.y - start.locationInWindow.y
            )
            guard CardDragGesture.shouldBeginDrag(
                travelled: travelled,
                clickCount: start.clickCount
            ) else {
                return
            }

            mouseDownEvent = nil
            coordinator?.beginDrag(from: self, event: start)
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDownEvent = nil }
            guard mouseDownEvent != nil, let coordinator else { return }
            if event.clickCount >= 2 {
                coordinator.owner.onDoubleTap()
            } else {
                coordinator.owner.onTap()
            }
        }

        /// The card is inside a non-activating panel; the drag must work without the
        /// overlay ever taking focus (docs/04 §5).
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }
}

extension CGRect {
    /// Centres a size inside this rect, for a drag image's frame.
    func centred(_ size: CGSize) -> CGRect {
        CGRect(
            x: midX - size.width / 2,
            y: midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Promise plus a `.fileURL` flavour so Terminal and Electron drop zones receive a path
/// (docs/16 OUT-6).
///
/// `nonisolated` so the `NSFilePromiseProvider` overrides stay off the module's default
/// main actor; pasteboard asks for types on AppKit's own thread.
///
/// It owns its delegate. `NSFilePromiseProvider.delegate` is weak and the provider is what
/// the pasteboard retains, so anchoring the delegate here is what makes the promise still
/// claimable once the drag — and the card that started it — is gone.
final nonisolated class KadrFilePromiseProvider: NSFilePromiseProvider {
    private var fulfiller: FilePromiseFulfiller?
    /// Already-final path, for the `.fileURL` flavour; nil for a staged capture, which has
    /// no path to promise until the receiver asks.
    private(set) var resolvedFileURL: URL?
    private var pathHandedOut: (@MainActor @Sendable () -> Void)?

    /// Built on top of `init()` rather than `init(fileType:delegate:)`, which reaches back
    /// through `init()` — a designated initializer here would trap on the way up.
    convenience init(payload: FilePromisePayload) {
        self.init()
        let fulfiller = FilePromiseFulfiller(payload: payload)
        self.fulfiller = fulfiller
        resolvedFileURL = payload.stableFileURL
        pathHandedOut = payload.pathHandedOut
        fileType = payload.contentType.identifier
        delegate = fulfiller
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if resolvedFileURL != nil, !types.contains(.fileURL) {
            types.append(.fileURL)
        }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL, let resolvedFileURL {
            if let pathHandedOut {
                if Thread.isMainThread {
                    MainActor.assumeIsolated { pathHandedOut() }
                } else {
                    Task { @MainActor in pathHandedOut() }
                }
            }
            // NSURL's own representation, not `absoluteString`: a receiver that reads the
            // flavour as data gets what `NSURL(pasteboardPropertyList:ofType:)` expects.
            return (resolvedFileURL as NSURL).pasteboardPropertyList(forType: type)
        }
        return super.pasteboardPropertyList(forType: type)
    }
}
