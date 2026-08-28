import AnnotationModel
import SwiftUI

/// The tool picker and export controls (docs/03 §3).
struct EditorToolbar: View {
    @Bindable var model: EditorDocumentModel
    let onExport: (EditorRootView.ExportAction) -> Void
    var onAutoRedact: (() -> Void)?
    var onRemoveBackground: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            tools
            Divider().frame(height: 20)
            historyControls
            Spacer()
            if onAutoRedact != nil {
                autoRedact
                Divider().frame(height: 20)
            }
            if onRemoveBackground != nil {
                removeBackground
                Divider().frame(height: 20)
            }
            exportControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases, id: \.self) { tool in
                Button {
                    model.tool = tool
                } label: {
                    Image(systemName: tool.symbolName)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(model.tool == tool ? Color.accentColor.opacity(0.25) : .clear)
                )
                .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                .accessibilityLabel(tool.title)
            }
        }
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
