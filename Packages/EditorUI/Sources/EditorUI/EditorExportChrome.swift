import ControlKit
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
            if model.showsLockedNotice, model.isCanvasLocked {
                lockedNotice
            }
        }
    }

    private func exportProgress(_ action: EditorExportAction) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(action.progressTitle)
                .font(.callout)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 0)
            if model.canCancelExport {
                Button(String(localized: "Cancel", bundle: .module)) {
                    model.cancelExport()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, KadrSpace.large)
        .padding(.vertical, KadrSpace.medium)
        .editorFloatingCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(action.progressTitle)
    }

    private func exportFailure(_ failure: EditorExportFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // The shared failure look, so an editor failure reads like the agent's and the
            // studio's (docs/18 X-2).
            Image(systemName: FeedbackKind.error.symbolName)
                .foregroundStyle(FeedbackKind.error.tint)
                .accessibilityHidden(true)
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
        .padding(.horizontal, KadrSpace.large)
        .padding(.vertical, KadrSpace.medium)
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
        .padding(.horizontal, KadrSpace.large)
        .padding(.vertical, KadrSpace.medium)
        .editorFloatingCard()
        .task {
            try? await Task.sleep(for: .seconds(4))
            if model.highlighterFallback == message {
                model.highlighterFallback = nil
            }
        }
    }

    /// Why a drag on an annotation did nothing (docs/18 T-ED-12).
    private var lockedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "Objects are locked.", bundle: .module))
                .font(.callout)
            Spacer(minLength: 0)
            Button(String(localized: "Unlock", bundle: .module)) {
                model.isCanvasLocked = false
            }
            .controlSize(.small)
            Button {
                model.showsLockedNotice = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Dismiss", bundle: .module))
        }
        .padding(.horizontal, KadrSpace.large)
        .padding(.vertical, KadrSpace.medium)
        .editorFloatingCard()
        .help(String(localized: "Unlock with ⇧⌘L or the lock in the toolbar", bundle: .module))
        .onAppear {
            AccessibilityNotification.Announcement(
                String(localized: "Objects are locked.", bundle: .module)
            ).post()
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
        .padding(.horizontal, KadrSpace.large)
        .padding(.vertical, KadrSpace.medium)
        .editorFloatingCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Removing the background", bundle: .module))
    }
}
