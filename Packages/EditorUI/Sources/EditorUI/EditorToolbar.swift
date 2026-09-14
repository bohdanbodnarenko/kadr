import AnnotationModel
import SwiftUI

/// The tool picker and export controls (docs/03 §3, docs/14 UX-25).
///
/// `ViewThatFits` keeps the primary tools visible at the 760 pt minimum and moves rotate,
/// flip, and ML actions into overflow rather than clipping or shrinking below hit targets.
struct EditorToolbar: View {
    @Bindable var model: EditorDocumentModel
    @Binding var isInspectorPresented: Bool
    let onExport: (EditorRootView.ExportAction) -> Void
    var onAutoRedact: (() -> Void)?
    var onRemoveBackground: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            toolbarContent(compact: false)
            toolbarContent(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func toolbarContent(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if model.tool == .crop {
                historyControlsRow(compact: false)
                Divider().frame(height: 18)
                cropControls
            } else {
                tools
                Divider().frame(height: 18)
                historyControlsRow(compact: compact)
            }
            Spacer(minLength: 8)
            if model.tool != .crop {
                if compact {
                    overflowMenu
                } else {
                    mlActions
                }
                exportControls
            }
            inspectorToggle
        }
    }

    private var cropControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "crop")
                .foregroundStyle(.secondary)
            Picker("Ratio", selection: Binding(
                get: { model.cropAspect },
                set: { model.applyCropAspect($0) }
            )) {
                ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 120)
            .help("Aspect ratio")

            if model.document.crop != nil {
                Button("Reset") { model.clearCrop() }
                    .controlSize(.small)
            }

            Button("Done") {
                model.selectTool(.select)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Finish cropping (Escape)")
        }
    }

    @ViewBuilder
    private var mlActions: some View {
        if onAutoRedact != nil {
            autoRedact
        }
        if onRemoveBackground != nil {
            removeBackground
        }
    }

    private var overflowMenu: some View {
        Menu {
            if onAutoRedact != nil {
                Button("Auto-redact") { onAutoRedact?() }
                    .disabled(model.isFindingRedactions)
            }
            if onRemoveBackground != nil {
                Button(
                    model.hasSubjectLift ? "Restore Background" : "Remove Background"
                ) { onRemoveBackground?() }
                    .disabled(model.isLiftingSubject)
            }
            Divider()
            Button("Rotate 90° Clockwise") { model.rotateClockwise() }
            Button("Flip Horizontal") { model.flipHorizontal() }
            Button("Flip Vertical") { model.flipVertical() }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .help("More tools")
        .accessibilityLabel("More tools")
    }

    private var autoRedact: some View {
        Button {
            onAutoRedact?()
        } label: {
            Label("Auto-redact", systemImage: "eye.slash")
        }
        .help("Find emails, cards, and keys, then review before blurring")
        .disabled(model.isFindingRedactions || model.isExporting)
        .controlSize(.small)
    }

    private var removeBackground: some View {
        Button {
            onRemoveBackground?()
        } label: {
            Label(
                model.hasSubjectLift ? "Restore Background" : "Remove Background",
                systemImage: model.hasSubjectLift ? "person.crop.square.fill" : "person.and.background.dotted"
            )
        }
        .help("Cut the subject out of the capture, on this Mac, with no network")
        .disabled(model.isLiftingSubject || model.isExporting)
        .controlSize(.small)
    }

    private var tools: some View {
        HStack(spacing: 8) {
            toolGroup([.select])
            toolGroup([.arrow, .shape, .line, .freehand, .highlighter, .text])
            toolGroup([.redaction, .spotlight, .counter, .sticker, .crop, .measure])
        }
    }

    private func toolGroup(_ tools: [EditorTool]) -> some View {
        HStack(spacing: 1) {
            ForEach(tools, id: \.self) { tool in
                Button {
                    model.selectTool(tool)
                } label: {
                    Image(systemName: tool.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 26)
                        .foregroundStyle(model.tool == tool ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.borderless)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(model.tool == tool ? Color.accentColor.opacity(0.18) : .clear)
                }
                .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func historyControlsRow(compact: Bool) -> some View {
        HStack(spacing: 2) {
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .help("Undo")

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .help("Redo")

            Divider().frame(height: 14)

            Button {
                model.isCanvasLocked.toggle()
            } label: {
                Image(systemName: model.isCanvasLocked ? "lock.fill" : "lock.open")
            }
            .help(model.isCanvasLocked ? "Unlock objects (⇧⌘L)" : "Lock objects in place while drawing (⇧⌘L)")
            .accessibilityLabel(model.isCanvasLocked ? "Unlock objects" : "Lock objects")

            if !compact {
                Button {
                    model.rotateClockwise()
                } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate 90° Clockwise")
                .accessibilityLabel("Rotate 90 degrees clockwise")

                Button {
                    model.flipHorizontal()
                } label: {
                    Image(systemName: "flip.horizontal")
                }
                .help("Flip Horizontal")
                .accessibilityLabel("Flip horizontal")

                Button {
                    model.flipVertical()
                } label: {
                    Image(systemName: "flip.horizontal")
                        .rotationEffect(.degrees(90))
                }
                .help("Flip Vertical")
                .accessibilityLabel("Flip vertical")
            }
        }
        .buttonStyle(.borderless)
    }

    private var exportControls: some View {
        HStack(spacing: 8) {
            Button("Copy") {
                onExport(.copy)
            }
            .disabled(model.isExporting)

            Menu {
                Button("Copy Flattened Image") {
                    onExport(.copyFlattened)
                }
                Button("Copy Without Annotations") {
                    onExport(.copyWithoutAnnotations)
                }
                Divider()
                Button("Insert Image…") {
                    onExport(.insertImage)
                }
                Button("Pin") {
                    onExport(.pin)
                }
                Button("Share…") {
                    onExport(.share)
                }
                Button("Print…") {
                    onExport(.print)
                }
                Divider()
                Button("Save As…") {
                    onExport(.saveAs)
                }
                Button("Save Project…") {
                    onExport(.saveProject)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 36)
            .disabled(model.isExporting)

            Button("Save") {
                onExport(.save)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isExporting)
        }
    }

    private var inspectorToggle: some View {
        Button {
            isInspectorPresented.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("i", modifiers: [.command, .option])
        .help(isInspectorPresented ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        .accessibilityLabel(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
    }
}
