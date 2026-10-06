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
            EditorToolbarButton(
                symbol: "doc.on.doc",
                help: String(localized: "Copy — or drag to hand the image to another app", bundle: .module),
                accessibilityLabel: "Copy"
            ) {
                onExport(.copy)
            }
            .disabled(model.isExporting || isCropping)
            // Dragging Copy hands over the flattened image, rendered when dropped: the
            // title-bar proxy is the file on disk, which may predate the edits (docs/18 ED-3).
            .onDrag { model.flattenedImageItemProvider() ?? NSItemProvider() }
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
            Button(String(localized: "Save", bundle: .module)) {
                onExport(.save)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isExporting || isCropping)
            .help(Text("Save", bundle: .module))
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
            Button(String(localized: "Rotate 90° Clockwise", bundle: .module)) { model.rotateClockwise() }
            Button(String(localized: "Flip Horizontal", bundle: .module)) { model.flipHorizontal() }
            Button(String(localized: "Flip Vertical", bundle: .module)) { model.flipVertical() }
            Divider()
            Button(String(localized: "Copy Flattened Image", bundle: .module)) { onExport(.copyFlattened) }
            Button(String(localized: "Copy Without Annotations", bundle: .module)) { onExport(.copyWithoutAnnotations) }
            Divider()
            Button(String(localized: "Insert Image…", bundle: .module)) { onExport(.insertImage) }
            Button(String(localized: "Pin", bundle: .module)) { onExport(.pin) }
            Button(String(localized: "Share…", bundle: .module)) { onExport(.share) }
            Button(String(localized: "Print…", bundle: .module)) { onExport(.print) }
            Divider()
            Button(String(localized: "Save As…", bundle: .module)) { onExport(.saveAs) }
            Button(String(localized: "Save Project…", bundle: .module)) { onExport(.saveProject) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 32, height: 28)
        .disabled(model.isExporting)
        .help(Text("More", bundle: .module))
        .accessibilityLabel(Text("More actions", bundle: .module))
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
        .padding(KadrSpace.xxs)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: KadrRadius.large, style: .continuous)
        )
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
                .font(.system(size: KadrType.title, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: KadrRadius.medium, style: .continuous).fill(fill))
                .contentShape(RoundedRectangle(cornerRadius: KadrRadius.medium, style: .continuous))
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
            .padding(.horizontal, KadrSpace.xxs)
    }
}
