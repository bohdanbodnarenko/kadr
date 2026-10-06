import AnnotationModel
import ControlKit
import SwiftUI

/// The Style pane: the armed tool, or the selection, and nothing else (docs/14 UX-30).
struct EditorStylePane: View {
    @Bindable var model: EditorDocumentModel

    /// The annotation whose style controls apply, excluding the ones with panels of their own.
    private var styledTool: AnnotationTool? {
        guard let tool = model.inspectedTool, tool != .crop, tool != .image else { return nil }
        return tool
    }

    private var showsSubjectLift: Bool {
        model.hasSubjectLift || model.subjectLiftError != nil
    }

    var body: some View {
        if model.tool == .crop {
            EditorCropInspector(model: model)
        } else if model.tool == .sticker {
            InspectorGroup("Sticker") {
                EmojiStickerPicker(selected: $model.stickerEmoji)
            }
        } else if let tool = styledTool {
            InspectorGroup(
                title(for: tool),
                accessory: { selectionActions },
                content: { EditorToolOptions(model: model, tool: tool) }
            )
        }

        if let image = model.selectedImage {
            imageGroup(image)
        }

        if showsSubjectLift {
            subjectLiftGroup
        }

        if isShowingNothing {
            InspectorEmptyState(
                symbol: "cursorarrow.rays",
                title: "Nothing selected",
                message: "Pick a tool or select an annotation to change how it looks."
            )
        }
    }

    private var isShowingNothing: Bool {
        model.tool != .crop
            && model.tool != .sticker
            && styledTool == nil
            && model.selectedImage == nil
            && !showsSubjectLift
    }

    private func title(for tool: AnnotationTool) -> String {
        let count = model.selection.count
        return count > 1 ? "\(tool.title) · \(count) selected" : tool.title
    }

    /// Duplicate and delete sit in the header of whatever is selected, not in a section of
    /// their own below it.
    @ViewBuilder
    private var selectionActions: some View {
        if !model.selection.isEmpty {
            InspectorIconButton(systemName: "plus.square.on.square", help: "Duplicate") {
                model.duplicateSelection()
            }
            InspectorIconButton(systemName: "trash", help: "Delete") {
                model.deleteSelection()
            }
        }
    }

    private func imageGroup(_ image: ImageSpec) -> some View {
        InspectorGroup("Image", accessory: { selectionActions }, content: {
            KadrSlider(
                title: "Size",
                value: Binding(
                    get: { Double(image.scaleFactor) },
                    set: { factor in model.updateSelectedImageLive { $0.scale(to: CGFloat(factor)) } }
                ),
                range: 0.1 ... 4,
                format: .multiplier,
                onEditingEnded: { model.endInspectorStyleEdit() }
            )
            KadrSlider(
                title: "Opacity",
                value: Binding(
                    get: { image.opacity },
                    set: { value in model.updateSelectedImageLive { $0.opacity = value } }
                ),
                range: 0.1 ... 1,
                format: .percent,
                onEditingEnded: { model.endInspectorStyleEdit() }
            )
            KadrSlider(
                title: "Corners",
                value: Binding(
                    get: { Double(image.cornerRadius) },
                    set: { value in model.updateSelectedImageLive { $0.cornerRadius = CGFloat(value) } }
                ),
                range: 0 ... 40,
                format: .points,
                onEditingEnded: { model.endInspectorStyleEdit() }
            )
            InspectorToggleRow("Shadow", isOn: Binding(
                get: { image.hasShadow },
                set: { value in model.updateSelectedImage { $0.hasShadow = value } }
            ))
        })
    }

    private var subjectLiftGroup: some View {
        InspectorGroup("Background") {
            if let message = model.subjectLiftError {
                InspectorNote(message)
            }
            if model.hasSubjectLift {
                InspectorSegmented(
                    [true, false],
                    selection: Binding(
                        get: { model.subjectLiftBackground.color == nil },
                        set: { isTransparent in
                            model.setSubjectLiftBackground(isTransparent ? .transparent : .color(.white))
                        }
                    ),
                    title: { $0 ? "Transparent" : "Color" }
                )

                if let colour = model.subjectLiftBackground.color {
                    InspectorColorRow("Color", selection: Binding(
                        get: { Color(colour) },
                        set: { model.setSubjectLiftBackground(.color(AnnotationColor($0))) }
                    ))
                }
                InspectorNote(
                    "Transparent exports as PNG whatever the format setting says — "
                        + "JPEG has no alpha channel to put the cut-out in."
                )
            }
        }
    }
}
