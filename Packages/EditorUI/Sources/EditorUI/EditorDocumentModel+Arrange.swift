import AnnotationModel
import CoreGraphics
import Foundation

/// Align and distribute, as one undo step each (docs/18 ED-7).
@MainActor
public extension EditorDocumentModel {
    /// Whether align has something to do: one item aligns to the canvas.
    var canAlignSelection: Bool {
        !isCanvasLocked && !selectedArrangeableCommands.isEmpty
    }

    /// Whether distribute has something to do: it needs three items.
    var canDistributeSelection: Bool {
        !isCanvasLocked && selectedArrangeableCommands.count >= 3
    }

    func alignSelection(_ alignment: SelectionArrangement.Alignment) {
        guard canAlignSelection else { return }
        let commands = selectedArrangeableCommands
        let moves = SelectionArrangement.align(
            commands.map(AnnotationHitTesting.boundingBox),
            alignment,
            canvas: document.contentRect
        )
        apply(moves, to: commands)
    }

    func distributeSelection(along axis: SelectionArrangement.Axis) {
        guard canDistributeSelection else { return }
        let commands = selectedArrangeableCommands
        let boxes = commands.map(AnnotationHitTesting.boundingBox)
        apply(SelectionArrangement.distribute(boxes, along: axis), to: commands)
    }

    private var selectedArrangeableCommands: [AnnotationCommand] {
        let selection = document.selection
        return document.commands.filter { selection.contains($0.id) && !$0.tool.isCanvasChrome }
    }

    private func apply(_ moves: [CGSize], to commands: [AnnotationCommand]) {
        var deltas: [AnnotationID: CGSize] = [:]
        for (command, move) in zip(commands, moves) where move != .zero {
            deltas[command.id] = move
        }
        guard !deltas.isEmpty else { return }
        document.perform { all in
            for index in all.indices {
                if let delta = deltas[all[index].id] {
                    all[index] = Self.translated(all[index], by: delta)
                }
            }
        }
    }
}
