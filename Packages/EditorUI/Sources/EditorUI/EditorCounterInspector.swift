import AnnotationModel
import SwiftUI

/// Size, colour and numbering for counter badges (docs/03 §3).
///
/// These are tool-level, not per-badge: picking Large or blue rewrites every number on
/// the canvas so a sequence stays one family. Badges are not free-resized.
struct EditorCounterInspector: View {
    @Bindable var model: EditorDocumentModel

    var body: some View {
        EditorSwatchStrip(
            selected: inspectedFill,
            onSelect: { model.applyCounterFill($0) }
        )

        Picker("Size", selection: Binding(
            get: { inspectedSize },
            set: { model.applyCounterSize($0) }
        )) {
            ForEach(CounterBadgeSize.allCases, id: \.self) { size in
                Text(size.shortTitle)
                    .tag(size)
                    .accessibilityLabel(size.title)
            }
        }
        .pickerStyle(.segmented)
        .help("Badge size")
        .accessibilityLabel("Badge size")

        Picker("Numbering", selection: Binding(
            get: { inspectedNumbering },
            set: { model.applyCounterNumbering($0) }
        )) {
            ForEach(CounterNumbering.allCases, id: \.self) { numbering in
                Text(numbering.title).tag(numbering)
            }
        }
    }

    private var inspectedFill: AnnotationColor {
        firstCounter?.fill ?? model.styleMemory.lastCounterFill
    }

    private var inspectedSize: CounterBadgeSize {
        if let radius = firstCounter?.radius {
            return CounterBadgeSize.matching(radius)
        }
        return model.styleMemory.lastCounterSize
    }

    private var inspectedNumbering: CounterNumbering {
        firstCounter?.numberingStyle ?? model.styleMemory.lastCounterNumbering
    }

    private var firstCounter: CounterSpec? {
        if let id = model.selection.first, case let .counter(spec)? = model.document.command(id) {
            return spec
        }
        for command in model.document.commands {
            if case let .counter(spec) = command {
                return spec
            }
        }
        return nil
    }
}
