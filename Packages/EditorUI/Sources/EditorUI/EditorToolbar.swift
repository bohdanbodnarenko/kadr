import AnnotationModel
import SwiftUI

/// The tool picker and export controls (docs/03 §3).
struct EditorToolbar: View {
    @Bindable var model: EditorDocumentModel
    @Binding var isInspectorPresented: Bool
    let onExport: (EditorRootView.ExportAction) -> Void
    var onAutoRedact: (() -> Void)?
    var onRemoveBackground: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if model.tool == .crop {
                historyControls
                Divider().frame(height: 18)
                cropControls
            } else {
                tools
                Divider().frame(height: 18)
                historyControls
            }
            Spacer(minLength: 8)
            if model.tool != .crop {
                if onAutoRedact != nil {
                    autoRedact
                }
                if onRemoveBackground != nil {
                    removeBackground
                }
                exportControls
            }
            Button {
                isInspectorPresented.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("i", modifiers: .command)
            .help(isInspectorPresented ? "Hide Inspector (⌘I)" : "Show Inspector (⌘I)")
            .accessibilityLabel(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
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

    private var autoRedact: some View {
        Button {
            onAutoRedact?()
        } label: {
            Label("Auto-redact", systemImage: "eye.slash")
        }
        .help("Find emails, cards, and keys, then review before blurring")
        .disabled(model.isFindingRedactions)
        .controlSize(.small)
    }

    /// One button that both applies and undoes the lift, because it is one decision.
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
        .disabled(model.isLiftingSubject)
        .controlSize(.small)
    }

    private var tools: some View {
        HStack(spacing: 8) {
            toolGroup([.select])
            toolGroup([.arrow, .shape, .line, .freehand, .highlighter, .text])
            toolGroup([.redaction, .counter, .crop, .measure])
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

    private var historyControls: some View {
        HStack(spacing: 2) {
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo")

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo")
        }
        .buttonStyle(.borderless)
    }

    private var exportControls: some View {
        HStack(spacing: 8) {
            Button("Copy") {
                onExport(.copy)
            }
            .keyboardShortcut("c", modifiers: .command)

            Menu {
                Button("Copy Without Annotations") {
                    onExport(.copyWithoutAnnotations)
                }
                Divider()
                // A project keeps the annotations editable rather than flattening them,
                // which is the whole point of the `.kadr` format (docs/04 §6).
                Button("Save Project…") {
                    onExport(.saveProject)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 36)

            Button("Save") {
                onExport(.save)
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
        }
    }
}
