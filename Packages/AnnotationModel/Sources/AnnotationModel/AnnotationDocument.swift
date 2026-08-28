import CoreGraphics
import Foundation

/// The immutable image an annotation document sits on (docs/04 §6).
public struct BaseImageReference: Codable, Hashable, Sendable {
    /// Size in points; the pixel size is this multiplied by `scale`.
    public var size: CGSize
    public var scale: CGFloat

    public init(size: CGSize, scale: CGFloat = 2) {
        self.size = size
        self.scale = max(scale, 1)
    }

    public var pixelSize: CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    public var bounds: CGRect {
        CGRect(origin: .zero, size: size)
    }
}

/// An annotated capture (docs/04 §6).
///
/// The base image never changes; every annotation is a value in an ordered list, and
/// undo is a matter of keeping previous lists. That is what makes annotations editable
/// forever, exports lossless, and "flatten" a thing that only happens on the way out.
public struct AnnotationDocument: Codable, Hashable, Sendable {
    /// Undo depth. Doc 03 §3 asks for at least 100; the extra is free because a command
    /// list is a few hundred bytes.
    public static let undoDepth = 128

    public let baseImage: BaseImageReference

    /// Every version of the command list, oldest first, with `historyIndex` pointing at
    /// the current one.
    private var history: [[AnnotationCommand]]
    private var historyIndex: Int

    /// The command list as it was when the current gesture opened, or nil when no gesture
    /// is in progress. Never encoded: a gesture cannot outlive the drag that opened it,
    /// so a document saved mid-drag reopens with the gesture already resolved.
    private var gestureBaseline: [AnnotationCommand]?

    public var selection: Set<AnnotationID>

    public init(baseImage: BaseImageReference, commands: [AnnotationCommand] = []) {
        self.baseImage = baseImage
        history = [commands]
        historyIndex = 0
        selection = []
    }

    /// The gesture baseline is deliberately absent: it is transient UI state that belongs
    /// to a drag in progress, and a decoded document is never mid-drag.
    private enum CodingKeys: String, CodingKey {
        case baseImage
        case history
        case historyIndex
        case selection
    }

    /// The annotations as they stand, in back-to-front order.
    public var commands: [AnnotationCommand] {
        history[historyIndex]
    }

    public var isEmpty: Bool {
        commands.isEmpty
    }

    public func command(_ id: AnnotationID) -> AnnotationCommand? {
        commands.first { $0.id == id }
    }

    public func index(of id: AnnotationID) -> Int? {
        commands.firstIndex { $0.id == id }
    }

    /// The crop in force, if any. The last one wins, so a re-crop supersedes.
    public var crop: CropSpec? {
        commands.reversed().compactMap { command in
            if case let .crop(spec) = command {
                return spec
            }
            return nil
        }.first
    }

    /// The beautify chrome in force, if any. The last one wins.
    public var beautify: BeautifySpec? {
        commands.reversed().compactMap { command in
            if case let .beautify(spec) = command {
                return spec
            }
            return nil
        }.first
    }

    /// The background removal in force, if any. The last one wins.
    public var subjectLift: SubjectLiftSpec? {
        commands.reversed().compactMap { command in
            if case let .subjectLift(spec) = command {
                return spec
            }
            return nil
        }.first
    }

    /// Replaces the background removal, or clears it. One undo step either way — unlike
    /// beautify's slider edits, this is a decision rather than a drag.
    public mutating func setSubjectLift(_ spec: SubjectLiftSpec?) {
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

    /// The capture area that is composed onto the canvas: the crop, or the whole image.
    public var contentRect: CGRect {
        crop?.rect ?? baseImage.bounds
    }

    /// The canvas the export will produce: beautify's frame, or the crop, or the image.
    public var canvasRect: CGRect {
        guard let beautify else { return contentRect }
        let layout = BeautifyLayout.compute(contentSize: contentRect.size, spec: beautify)
        return CGRect(origin: .zero, size: layout.canvasSize)
    }

    /// Where the capture sits on a beautified canvas, or `nil` when there is no chrome.
    public var beautifyLayout: BeautifyLayout? {
        guard let beautify else { return nil }
        return BeautifyLayout.compute(contentSize: contentRect.size, spec: beautify)
    }

    /// Replaces the current beautify command, coalescing successive inspector edits into
    /// one undo step so dragging a slider does not flood the undo stack.
    public mutating func setBeautify(_ spec: BeautifySpec?) {
        var updated = commands
        updated.removeAll { command in
            if case .beautify = command {
                return true
            }
            return false
        }
        if let spec {
            updated.insert(.beautify(spec), at: 0)
        }
        guard updated != commands else { return }
        if shouldCoalesceBeautify(updated) {
            history[historyIndex] = updated
            return
        }
        pushHistory(updated)
    }

    private func shouldCoalesceBeautify(_ updated: [AnnotationCommand]) -> Bool {
        guard historyIndex > 0, historyIndex == history.count - 1 else { return false }
        func isBeautify(_ command: AnnotationCommand) -> Bool {
            if case .beautify = command {
                return true
            }
            return false
        }
        // Only successive inspector edits coalesce. Turning beautify on or off is its
        // own undo step, otherwise "Add a background" and "remove it" collapse into one.
        guard commands.contains(where: isBeautify), updated.contains(where: isBeautify) else {
            return false
        }
        func withoutBeautify(_ list: [AnnotationCommand]) -> [AnnotationCommand] {
            list.filter { !isBeautify($0) }
        }
        return withoutBeautify(commands) == withoutBeautify(history[historyIndex - 1])
            && withoutBeautify(updated) == withoutBeautify(history[historyIndex - 1])
    }

    // MARK: - Editing

    /// Applies a change and records it for undo.
    ///
    /// Everything that mutates the document funnels through here, so there is exactly one
    /// place where history is maintained and no way to forget.
    public mutating func perform(_ change: (inout [AnnotationCommand]) -> Void) {
        var updated = commands
        change(&updated)
        guard updated != commands else { return }
        pushHistory(updated)
    }

    public mutating func add(_ command: AnnotationCommand) {
        perform { $0.append(command) }
        renumberCounters()
    }

    // MARK: - Gestures (docs/09 U0.2)

    /// Opens a gesture: a run of live edits that must land as **one** undo step.
    ///
    /// A drag produces a mouse-moved event every frame. Routing those through `perform`
    /// pushes an entry each time, which fills a 128-deep stack in under two seconds of
    /// dragging and makes ⌘Z useless. Inside a gesture the edits amend the current entry
    /// instead, and `endGesture` turns the whole run into a single step.
    ///
    /// Re-entrant calls are ignored, so a stray `pointerDown` cannot orphan a baseline.
    public mutating func beginGesture() {
        guard gestureBaseline == nil else { return }
        gestureBaseline = commands
    }

    /// Whether a gesture is open. The view layer uses this to keep its live-drag path
    /// and its rebuild-everything path from fighting.
    public var isGestureOpen: Bool {
        gestureBaseline != nil
    }

    /// A live edit inside a gesture. Outside one it behaves exactly like `perform`, so a
    /// caller that forgets to open a gesture still gets correct — if noisier — history.
    public mutating func updateGesture(_ change: (inout [AnnotationCommand]) -> Void) {
        guard gestureBaseline != nil else {
            perform(change)
            return
        }
        var updated = commands
        change(&updated)
        guard updated != commands else { return }
        history[historyIndex] = updated
    }

    /// Closes the gesture, leaving exactly one undo step for everything it did.
    ///
    /// The pre-gesture state is put back into the current slot and the final state is
    /// pushed on top, so undo lands where the user started the drag rather than somewhere
    /// in the middle of it. A gesture that changed nothing — a click that did not move —
    /// leaves history untouched.
    @discardableResult
    public mutating func endGesture() -> Bool {
        guard let baseline = gestureBaseline else { return false }
        gestureBaseline = nil

        let final = commands
        history[historyIndex] = baseline
        guard final != baseline else { return false }
        pushHistory(final)
        return true
    }

    public mutating func remove(_ ids: Set<AnnotationID>) {
        guard !ids.isEmpty else { return }
        perform { $0.removeAll { ids.contains($0.id) } }
        selection.subtract(ids)
        renumberCounters()
    }

    /// Replaces one annotation in place, keeping its z-order.
    public mutating func update(_ command: AnnotationCommand) {
        perform { commands in
            guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
            commands[index] = command
        }
    }

    // MARK: - Undo and redo

    public var canUndo: Bool {
        historyIndex > 0
    }

    public var canRedo: Bool {
        historyIndex < history.count - 1
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard canUndo else { return false }
        historyIndex -= 1
        pruneSelection()
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard canRedo else { return false }
        historyIndex += 1
        pruneSelection()
        return true
    }

    private mutating func pushHistory(_ commands: [AnnotationCommand]) {
        // Anything undone is discarded the moment a new edit lands, which is what every
        // editor does and what users expect.
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(commands)
        if history.count > Self.undoDepth {
            history.removeFirst(history.count - Self.undoDepth)
        }
        historyIndex = history.count - 1
    }

    /// Drops selected ids that no longer exist, so undoing a delete does not leave the
    /// selection pointing at ghosts.
    private mutating func pruneSelection() {
        let live = Set(commands.map(\.id))
        selection.formIntersection(live)
    }

    // MARK: - Z-order

    public mutating func bringToFront(_ ids: Set<AnnotationID>) {
        reorder(ids) { commands, moved in commands + moved }
    }

    public mutating func sendToBack(_ ids: Set<AnnotationID>) {
        reorder(ids) { commands, moved in moved + commands }
    }

    public mutating func bringForward(_ ids: Set<AnnotationID>) {
        shift(ids, by: 1)
    }

    public mutating func sendBackward(_ ids: Set<AnnotationID>) {
        shift(ids, by: -1)
    }

    private mutating func reorder(
        _ ids: Set<AnnotationID>,
        _ combine: ([AnnotationCommand], [AnnotationCommand]) -> [AnnotationCommand]
    ) {
        guard !ids.isEmpty else { return }
        perform { commands in
            let moved = commands.filter { ids.contains($0.id) }
            guard !moved.isEmpty else { return }
            let rest = commands.filter { !ids.contains($0.id) }
            commands = combine(rest, moved)
        }
        renumberCounters()
    }

    private mutating func shift(_ ids: Set<AnnotationID>, by offset: Int) {
        guard !ids.isEmpty, offset != 0 else { return }
        perform { commands in
            // Walk from the end when moving forward so two adjacent selected items do not
            // swap past each other.
            let indices = commands.indices.filter { ids.contains(commands[$0].id) }
            for index in offset > 0 ? indices.reversed() : indices {
                let target = index + offset
                guard commands.indices.contains(target), !ids.contains(commands[target].id) else { continue }
                commands.swapAt(index, target)
            }
        }
        renumberCounters()
    }

    // MARK: - Counters

    /// Renumbers counter badges 1…n in z-order (docs/03 §3: dragging to reorder
    /// renumbers).
    ///
    /// Called after anything that changes order or membership, so the numbers a user sees
    /// are always a consequence of the stack rather than of the order they happened to
    /// draw them in.
    public mutating func renumberCounters() {
        var next = 1
        var updated = commands
        var changed = false

        for index in updated.indices {
            guard case var .counter(spec) = updated[index] else { continue }
            if spec.number != next {
                spec.number = next
                updated[index] = .counter(spec)
                changed = true
            }
            next += 1
        }

        guard changed else { return }
        // Renumbering is a consequence of another edit, not an edit in its own right, so
        // it amends the current history entry instead of adding one. Otherwise every
        // counter operation would need two undos.
        history[historyIndex] = updated
    }

    /// The number the next counter badge would get.
    public var nextCounterNumber: Int {
        commands.reduce(0) { count, command in
            if case .counter = command {
                return count + 1
            }
            return count
        } + 1
    }
}
