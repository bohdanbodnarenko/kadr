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

    init(
        suggestedName: String,
        contentType: UTType,
        resolve: @escaping @MainActor @Sendable () -> URL?,
        completed: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
    ) {
        self.suggestedName = suggestedName
        self.contentType = contentType
        self.resolve = resolve
        self.completed = completed
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
            completed: completed
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
/// dragging source and the promise delegate for the session's lifetime — and because both
/// the SwiftUI cards and the AppKit pin windows need the same behaviour.
@MainActor
final class FilePromiseDragController: NSObject, NSFilePromiseProviderDelegate, NSDraggingSource {
    private let logger = KadrLog.logger(.overlay)

    /// The payload for the drag in flight. Held for the session's lifetime because the
    /// promise is fulfilled long after `beginDraggingSession` returns.
    private var inFlight: FilePromisePayload?

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

    /// Starts a promise drag from `view`, using `event` as the drag's origin.
    func beginDrag(from view: NSView, event: NSEvent, payload: FilePromisePayload, image: NSImage?) {
        inFlight = payload

        let provider = NSFilePromiseProvider(fileType: payload.contentType.identifier, delegate: self)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let size = image?.size ?? CGSize(width: 64, height: 64)
        item.setDraggingFrame(view.bounds.centred(size), contents: image)

        view.beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        inFlight?.suggestedName ?? "Capture"
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
        Task { [inFlight, logger] in
            guard let source = await MainActor.run(body: { inFlight?.resolve() }) else {
                logger.error("A promised drag had no file to hand over")
                completionHandler(CocoaError(.fileNoSuchFile))
                return
            }
            do {
                // Off the main actor: a recording can be hundreds of megabytes, and the
                // receiving app is waiting on this copy.
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }.value
                completionHandler(nil)
            } catch {
                logger.error("Promised drag failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
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
        // `.none` is the user letting go over nothing, or pressing Escape. Anything else
        // means a receiver took it — the only moment a card may be dismissed (U0.1).
        payload?.completed(!operation.isEmpty)
    }
}

/// A SwiftUI drag source that hands over a file promise.
///
/// The view owns the whole mouse interaction — click, double-click and drag — because
/// splitting them between SwiftUI gestures and an AppKit drag source is what makes drags
/// start when the user meant to click.
struct FilePromiseDragView: NSViewRepresentable {
    /// Built at drag time, so it always reflects the item's current state.
    var payload: @MainActor () -> FilePromisePayload
    /// A snapshot to drag under the pointer. Nil drags a generic icon.
    var dragImage: @MainActor () -> NSImage?
    var onTap: @MainActor () -> Void = {}
    var onDoubleTap: @MainActor () -> Void = {}

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
            dragController.beginDrag(
                from: view,
                event: event,
                payload: owner.payload(),
                image: owner.dragImage()
            )
        }
    }

    /// The `NSView` that owns the mouse: clicks, double-clicks and the drag threshold.
    final class DragSourceView: NSView {
        var coordinator: Coordinator?
        private var mouseDownEvent: NSEvent?

        /// Below this a mouse-down-and-move is still a click, not a drag.
        private static let dragThreshold: CGFloat = 3

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownEvent else { return }
            let travelled = hypot(
                event.locationInWindow.x - start.locationInWindow.x,
                event.locationInWindow.y - start.locationInWindow.y
            )
            guard travelled >= Self.dragThreshold else { return }

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
