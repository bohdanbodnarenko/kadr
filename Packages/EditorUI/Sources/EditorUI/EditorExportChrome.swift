import SwiftUI

/// Export progress and failure chrome for the annotation editor (docs/14 UX-26).
struct EditorExportChrome: View {
    @Bindable var model: EditorDocumentModel
    let onRetry: (EditorExportAction) -> Void
    let onChooseAnotherLocation: (EditorExportAction) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let action = model.runningExport {
                exportProgress(action)
            }
            if let failure = model.exportFailure {
                exportFailure(failure)
            }
            if let notice = model.highlighterFallback {
                highlighterNotice(notice)
            }
            if model.isLiftingSubject {
                subjectLiftProgress
            }
        }
    }

    private func exportProgress(_ action: EditorExportAction) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(action.progressTitle)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .editorFloatingCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(action.progressTitle)
    }

    private func exportFailure(_ failure: EditorExportFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.title)
                    .font(.callout.weight(.semibold))
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(String(localized: "Retry", bundle: .module)) {
                        onRetry(failure.action)
                    }
                    if failure.offersAnotherLocation {
                        Button(String(localized: "Choose Another Location", bundle: .module)) {
                            onChooseAnotherLocation(failure.action)
                        }
                    }
                    Button(String(localized: "Dismiss", bundle: .module)) {
                        model.exportFailure = nil
                    }
                    .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .editorFloatingCard()
    }

    private func highlighterNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "highlighter")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                model.highlighterFallback = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .editorFloatingCard()
        .task {
            try? await Task.sleep(for: .seconds(4))
            if model.highlighterFallback == message {
                model.highlighterFallback = nil
            }
        }
    }

    private var subjectLiftProgress: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Removing the background…", bundle: .module)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .editorFloatingCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Removing the background", bundle: .module))
    }
}
