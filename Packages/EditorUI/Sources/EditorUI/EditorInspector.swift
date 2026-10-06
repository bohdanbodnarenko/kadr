import AnnotationModel
import ControlKit
import SwiftUI

/// Per-tool style and canvas controls (docs/03 §3, docs/14 UX-30).
///
/// Two panes behind a pinned switch, the way Keynote separates formatting from the document:
///
/// * **Style** — whatever the pointer is about to draw or has selected. Picking a tool or
///   selecting an object brings it forward, so its controls are first without scrolling.
/// * **Canvas** — looks and effects set once per capture, advanced ones folded by default,
///   then the export size.
///
/// Splitting them is what stops the panel jumping. Arming a tool used to insert or remove a
/// section at the top of one long grouped Form, shoving every global panel below it up and
/// down under the pointer. Now tool changes only redraw Style, and Canvas never moves. Only
/// the visible pane is built, so dragging an annotation — which rewrites the document every
/// frame — no longer re-evaluates six effect panels as it goes.
struct EditorInspector: View {
    @Bindable var model: EditorDocumentModel
    @AppStorage("editor.inspector.pane") private var pane: EditorInspectorPane = .style

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                switch pane {
                case .style:
                    EditorStylePane(model: model)
                case .canvas:
                    EditorCanvasPane(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, KadrSpace.xl)
        }
        .safeAreaInset(edge: .top, spacing: 0) { paneSwitcher }
        // A pane swap is a page turn, not a morph: animating it slid rows across each other.
        .transaction(value: pane) { $0.animation = nil }
        .onChange(of: model.tool) { _, tool in
            if tool != .select {
                pane = .style
            }
        }
        .onChange(of: model.selection) { _, selection in
            if !selection.isEmpty {
                pane = .style
            }
        }
    }

    private var paneSwitcher: some View {
        VStack(spacing: 0) {
            InspectorSegmented(EditorInspectorPane.allCases, selection: $pane, title: \.title)
                .padding(.horizontal, InspectorMetrics.horizontalPadding)
                .padding(.vertical, 10)
            Rectangle()
                .fill(InspectorControlPalette.separator)
                .frame(height: 0.5)
        }
        .background(.bar)
    }
}

enum EditorInspectorPane: String, CaseIterable {
    case style
    case canvas

    var title: String {
        switch self {
        case .style: "Style"
        case .canvas: "Canvas"
        }
    }
}

/// Looks, effects and output size — the controls that belong to the whole capture.
struct EditorCanvasPane: View {
    @Bindable var model: EditorDocumentModel

    var body: some View {
        EditorStylePresetInspector(model: model)
        EditorBeautifyInspector(model: model)
        EditorCameraInspector(model: model)
        EditorBlurInspector(model: model)
        EditorWatermarkInspector(model: model)
        EditorResizeInspector(model: model)
    }
}
