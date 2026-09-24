import AnnotationModel
import AppKit
import ControlKit
import SwiftUI

/// Everything a text annotation actually has (docs/03 §3, docs/14 UX-30A).
///
/// Text used to fall through to the generic stroke section, so the inspector offered five
/// stroke-width presets and a Width slider for an object that has no stroke — controls that
/// moved a number in style memory and changed nothing on screen. The preset picker had the
/// mirror-image problem: it wrote `lastTextStyle` and left the selected caption alone.
///
/// So: presets first, then the properties a preset is made of, all of them writing through
/// `applyTextStyle` so memory and selection move together as one undo step.
struct EditorTextInspector: View {
    @Bindable var model: EditorDocumentModel

    private var style: TextStyle {
        model.inspectedTextStyle
    }

    var body: some View {
        InspectorRow("Preset") {
            Picker("Preset", selection: presetBinding) {
                Text("Custom").tag(-1)
                ForEach(Array(TextStyle.presets.enumerated()), id: \.offset) { index, preset in
                    Text(preset.name).tag(index)
                }
            }
            .inspectorMenuPicker()
        }

        InspectorRow("Font") {
            Picker("Font", selection: fontBinding) {
                ForEach(EditorFontCatalog.families(including: style.fontName), id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .inspectorMenuPicker()
        }

        InspectorSegmented([false, true], selection: weightBinding, title: { $0 ? "Bold" : "Regular" })

        KadrSlider(
            title: "Size",
            value: Binding(
                get: { Double(style.fontSize) },
                set: { size in
                    var next = style
                    next.fontSize = CGFloat(size)
                    model.applyTextStyleLive(next)
                }
            ),
            range: Double(EditorDocumentModel.textSizeRange.lowerBound)
                ... Double(EditorDocumentModel.textSizeRange.upperBound),
            format: .points,
            onEditingEnded: { model.endInspectorStyleEdit() }
        )

        InspectorStackedRow("Colour") {
            EditorSwatchStrip(
                selected: style.color,
                onSelect: { colour in
                    var next = style
                    next.color = colour
                    model.applyTextStyle(next)
                }
            )
        }

        InspectorSegmented(
            options: Array(TextStyle.Alignment.allCases),
            selection: alignmentBinding,
            accessibilityTitle: \.title
        ) { alignment in
            Image(systemName: alignment.symbolName)
        }

        InspectorToggleRow("Background pill", isOn: pillBinding)

        if let background = style.backgroundColor {
            InspectorColorRow("Pill colour", selection: Binding(
                get: { Color(background) },
                set: { colour in
                    var next = style
                    next.backgroundColor = AnnotationColor(colour)
                    model.applyTextStyle(next)
                }
            ))
        }
    }

    // MARK: - Bindings

    /// `-1` is "none of the presets", which is what a custom style is.
    ///
    /// Without the Custom tag the picker shows whichever preset it last matched while the
    /// style no longer is one, and says the wrong thing about every hand-tuned caption.
    private var presetBinding: Binding<Int> {
        Binding(
            get: { TextStyle.presets.firstIndex { $0.style == style } ?? -1 },
            set: { index in
                guard TextStyle.presets.indices.contains(index) else { return }
                model.applyTextStyle(TextStyle.presets[index].style)
            }
        )
    }

    private var fontBinding: Binding<String> {
        Binding(
            get: { style.fontName },
            set: { family in
                var next = style
                next.fontName = family
                model.applyTextStyle(next)
            }
        )
    }

    private var weightBinding: Binding<Bool> {
        Binding(
            get: { style.isBold },
            set: { isBold in
                var next = style
                next.isBold = isBold
                model.applyTextStyle(next)
            }
        )
    }

    private var alignmentBinding: Binding<TextStyle.Alignment> {
        Binding(
            get: { style.alignment },
            set: { alignment in
                var next = style
                next.alignment = alignment
                model.applyTextStyle(next)
            }
        )
    }

    private var pillBinding: Binding<Bool> {
        Binding(
            get: { style.backgroundColor != nil },
            set: { hasPill in
                var next = style
                // The remembered pill colour rather than a fresh default, so toggling the
                // pill off to read the text and back on does not lose the colour choice.
                next.backgroundColor = hasPill
                    ? (model.styleMemory.lastTextStyle.backgroundColor ?? .black)
                    : nil
                model.applyTextStyle(next)
            }
        )
    }
}

/// The font families the text inspector offers.
///
/// Every installed family, the way a macOS font menu does — filtered of the families whose
/// names begin with a dot, which are system internals no one means to pick. The list is
/// built once: `availableFontFamilies` walks the font registry, and rebuilding it on every
/// inspector redraw would be a font enumeration per keystroke.
enum EditorFontCatalog {
    static let all: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted()

    /// The catalogue, plus a family the document is using that this Mac does not have.
    ///
    /// A `.kadr` made on another machine names a font that may be missing here. Dropping it
    /// from the picker would make the picker select something else and silently restyle the
    /// annotation on the next change.
    static func families(including current: String) -> [String] {
        guard !current.isEmpty, !all.contains(current) else { return all }
        return [current] + all
    }
}
