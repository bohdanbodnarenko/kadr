import AnnotationModel
import ControlKit
import SwiftUI

/// The tool palette, history and export controls (docs/03 §3, docs/14 UX-25).
///
/// One fixed layout in every state. The bar used to swap its whole contents for crop
/// controls and flip between two `ViewThatFits` variants, so arming Crop — or nudging the
/// window — re-laid every control under the pointer. Crop now has its own floating bar on
/// the canvas; rotate, flip, background removal and the secondary exports share one More
/// menu; and every control is a fixed-size target, so choosing a tool changes a highlight
/// and nothing else. Controls that do not apply right now are disabled, not removed.
struct EditorToolbar: View {
    @Bindable var model: EditorDocumentModel
    @Binding var isInspectorPresented: Bool
    let onExport: (EditorRootView.ExportAction) -> Void
    var onAutoRedact: (() -> Void)?
    var onRemoveBackground: (() -> Void)?
    /// Moves the capture to the Trash, after the host asks (docs/03 §3).
    var onDelete: (() -> Void)?

    static let height: CGFloat = 44

    private static let toolGroups: [[EditorTool]] = [
        [.select],
        [.arrow, .shape, .line, .freehand, .highlighter, .text],
        [.redaction, .spotlight, .counter, .sticker, .crop, .measure]
    ]

    private var isCropping: Bool {
        model.tool == .crop
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.toolGroups.enumerated()), id: \.offset) { _, tools in
                EditorToolGroup(tools: tools, selected: model.tool) { model.selectTool($0) }
            }
            EditorToolbarDivider()
            history
            Spacer(minLength: 6)
            if onAutoRedact != nil {
                EditorToolbarButton(
                    symbol: "eye.slash",
                    help: "Auto-redact — find emails, cards and keys, then review before blurring",
                    accessibilityLabel: "Auto-redact"
                ) {
                    onAutoRedact?()
                }
                .disabled(model.isFindingRedactions || model.isExporting || isCropping)
            }
            moreMenu
            EditorToolbarButton(symbol: "doc.on.doc", help: "Copy", accessibilityLabel: "Copy") {
                onExport(.copy)
            }
            .disabled(model.isExporting || isCropping)
            EditorToolbarDivider()
            // Beside Save, the other end of "done with this capture". It asks before it
            // moves anything, so it can sit this close to the commit button.
            if onDelete != nil {
                EditorToolbarButton(
                    symbol: "trash",
                    help: "Move to Trash",
                    accessibilityLabel: "Move capture to Trash"
                ) {
                    onDelete?()
                }
                .disabled(model.isExporting)
            }
            Button("Save") {
                onExport(.save)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isExporting || isCropping)
            .help("Save")
            EditorToolbarButton(
                symbol: "sidebar.right",
                help: isInspectorPresented ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)",
                isOn: isInspectorPresented,
                accessibilityLabel: isInspectorPresented ? "Hide Inspector" : "Show Inspector"
            ) {
                isInspectorPresented.toggle()
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(.bar)
    }

    private var history: some View {
        HStack(spacing: 1) {
            EditorToolbarButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", accessibilityLabel: "Undo") {
                model.undo()
            }
            .disabled(!model.canUndo)

            EditorToolbarButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", accessibilityLabel: "Redo") {
                model.redo()
            }
            .disabled(!model.canRedo)

            EditorToolbarButton(
                symbol: model.isCanvasLocked ? "lock.fill" : "lock.open",
                help: model.isCanvasLocked ? "Unlock objects (⇧⌘L)" : "Lock objects in place while drawing (⇧⌘L)",
                isOn: model.isCanvasLocked,
                accessibilityLabel: model.isCanvasLocked ? "Unlock objects" : "Lock objects"
            ) {
                model.isCanvasLocked.toggle()
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if onRemoveBackground != nil {
                Button(model.hasSubjectLift ? "Restore Background" : "Remove Background") {
                    onRemoveBackground?()
                }
                .disabled(model.isLiftingSubject || model.isExporting)
                Divider()
            }
            Button("Rotate 90° Clockwise") { model.rotateClockwise() }
            Button("Flip Horizontal") { model.flipHorizontal() }
            Button("Flip Vertical") { model.flipVertical() }
            Divider()
            Button("Copy Flattened Image") { onExport(.copyFlattened) }
            Button("Copy Without Annotations") { onExport(.copyWithoutAnnotations) }
            Divider()
            Button("Insert Image…") { onExport(.insertImage) }
            Button("Pin") { onExport(.pin) }
            Button("Share…") { onExport(.share) }
            Button("Print…") { onExport(.print) }
            Divider()
            Button("Save As…") { onExport(.saveAs) }
            Button("Save Project…") { onExport(.saveProject) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 32, height: 28)
        .disabled(model.isExporting)
        .help("More")
        .accessibilityLabel("More actions")
    }
}

/// A run of tools on one shared track.
private struct EditorToolGroup: View {
    let tools: [EditorTool]
    let selected: EditorTool
    let onSelect: (EditorTool) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(tools, id: \.self) { tool in
                EditorToolbarButton(
                    symbol: tool.symbolName,
                    help: "\(tool.title) (\(String(tool.shortcut).uppercased()))",
                    isOn: tool == selected,
                    accessibilityLabel: tool.title
                ) {
                    onSelect(tool)
                }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The toolbar's one control shape: a 28-pt target with a hover wash and an accent state.
struct EditorToolbarButton: View {
    let symbol: String
    let help: String
    var isOn = false
    var accessibilityLabel: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var fill: Color {
        if isOn {
            return Color.accentColor.opacity(0.16)
        }
        return isHovering && isEnabled ? KadrFill.hover : .clear
    }
}

private struct EditorToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }
}
