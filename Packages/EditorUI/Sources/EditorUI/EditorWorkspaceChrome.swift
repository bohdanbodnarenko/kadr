import AnnotationModel
import ControlKit
import SwiftUI

/// Neutral dotted workspace behind the capture, so a screenshot reads as a card rather
/// than a document page stuck to the window chrome.
struct EditorWorkspaceBackground: View {
    private let spacing: CGFloat = 18
    private let dotRadius: CGFloat = 1.1

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.93))

            Canvas { context, size in
                var path = Path()
                let offset = spacing / 2
                for x in stride(from: offset, through: size.width, by: spacing) {
                    for y in stride(from: offset, through: size.height, by: spacing) {
                        path.addEllipse(in: CGRect(
                            x: x - dotRadius,
                            y: y - dotRadius,
                            width: dotRadius * 2,
                            height: dotRadius * 2
                        ))
                    }
                }
                context.fill(path, with: .color(Color.secondary.opacity(0.14)))
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// The one surface every floating control on the workspace shares.
    func editorFloatingCard(cornerRadius: CGFloat = 12) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(KadrFill.stroke, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
    }
}

/// Fit / actual-size control that sits on the workspace, not in the toolbar.
struct EditorZoomControl: View {
    @Bindable var session: EditorCanvasSession

    var body: some View {
        Menu {
            Button("Zoom In") { session.zoomIn() }
            Button("Zoom Out") { session.zoomOut() }

            Divider()

            Button("Fit Canvas") { session.fit() }

            Divider()

            Button("50%") { session.setPercent(50) }
            Button("100%") { session.setPercent(100) }
            Button("200%") { session.setPercent(200) }
        } label: {
            Text(session.zoomToFit ? "Fit" : "\(session.zoomPercent)%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 38)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .editorFloatingCard(cornerRadius: 15)
        .help("Zoom. ⌘1 fits the capture, ⌘0 shows actual size.")
        .accessibilityLabel("Zoom")
        .accessibilityValue(session.zoomToFit ? "Fit" : "\(session.zoomPercent) percent")
    }
}

/// Live crop (or canvas) size, matching the zoom capsule on the other corner.
struct EditorCanvasSizeBadge: View {
    let size: CGSize

    var body: some View {
        Text("\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px")
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .fixedSize()
            .editorFloatingCard(cornerRadius: 15)
            .help("Size in pixels")
    }
}

/// Export progress, failures and the redaction review, floating over the top of the canvas.
///
/// These used to be strips stacked above the workspace, so each one that appeared shrank the
/// canvas's viewport and the capture re-fitted — a zoom jump for a progress message.
struct EditorWorkspaceBanners: View {
    @Bindable var model: EditorDocumentModel
    let onRetry: (EditorExportAction) -> Void
    let onChooseAnotherLocation: (EditorExportAction) -> Void
    let onFind: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            EditorExportChrome(
                model: model,
                onRetry: onRetry,
                onChooseAnotherLocation: onChooseAnotherLocation
            )
            if model.hasRedactionReviewChrome {
                EditorRedactionReviewStrip(model: model, onFind: onFind)
                    .transition(EditorMotion.transition(.move(edge: .top).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: 560)
        .editorAnimation(.snappy(duration: 0.22), value: model.hasRedactionReviewChrome)
    }
}

/// The crop mode's controls, on the canvas where the handles are (docs/03 §3).
struct EditorCropChrome: View {
    @Bindable var model: EditorDocumentModel

    var body: some View {
        ZStack {
            if model.tool == .crop {
                EditorCropBar(model: model)
                    .transition(EditorMotion.transition(.move(edge: .bottom).combined(with: .opacity)))
            }
        }
        .editorAnimation(.snappy(duration: 0.22), value: model.tool == .crop)
    }
}

/// Ratio, size, Reset and Done in one capsule — the crop bar Photos puts under the image.
///
/// "Crop is a mode until **Done**", so Done is always on screen while cropping, and owns
/// Return, whether or not the inspector is open.
private struct EditorCropBar: View {
    @Bindable var model: EditorDocumentModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("Ratio", selection: Binding(
                get: { model.cropAspect },
                set: { model.applyCropAspect($0) }
            )) {
                ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Aspect ratio")

            Text(sizeText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // Wide enough for four-digit sides, so dragging a handle does not make the
                // capsule breathe.
                .frame(minWidth: 104)
                .help("Size in pixels")

            Button("Reset") { model.clearCrop() }
                .disabled(model.document.crop == nil)
                .help("Put the crop back to the whole capture")

            Button("Done") { model.selectTool(.select) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Finish cropping (Return)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .fixedSize()
        .editorFloatingCard(cornerRadius: 22)
    }

    private var sizeText: String {
        let points = model.cropWorkingRect.size
        let scale = model.document.baseImage.scale
        return "\(Int((points.width * scale).rounded())) × \(Int((points.height * scale).rounded())) px"
    }
}
