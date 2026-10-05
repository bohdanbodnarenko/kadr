import AppKit
import SwiftUI

struct StudioFailureBanner: View {
    let failure: StudioFailurePresentation
    let onAction: (StudioFailurePresentation.Action) -> Void

    var body: some View {
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
                    actionButton(failure.primaryAction, title: primaryTitle(for: failure.primaryAction))
                    if let secondary = failure.secondaryAction {
                        actionButton(secondary, title: primaryTitle(for: secondary))
                            .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(radius: 6, y: 2)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(failure.title). \(failure.message)")
    }

    private func actionButton(_ action: StudioFailurePresentation.Action, title: String) -> some View {
        Button(title) { onAction(action) }
    }

    private func primaryTitle(for action: StudioFailurePresentation.Action) -> String {
        switch action {
        case .dismiss: "Dismiss"
        case .retry: "Retry"
        case .confirmLargeCuts: "Apply Cuts"
        case .openSpeechSettings: "Open Settings"
        case .chooseExportLocation: "Choose Another Location"
        }
    }
}

struct StudioFailureSheet: View {
    let failure: StudioFailurePresentation
    let onAction: (StudioFailurePresentation.Action) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(failure.title)
                .font(.headline)
            Text(failure.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if failure.secondaryAction == .dismiss {
                    Button(String(localized: "Cancel", bundle: .module)) {
                        onAction(.dismiss)
                        dismiss()
                    }
                }
                Button(primaryTitle(for: failure.primaryAction)) {
                    onAction(failure.primaryAction)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func primaryTitle(for action: StudioFailurePresentation.Action) -> String {
        switch action {
        case .dismiss: "OK"
        case .retry: "Retry"
        case .confirmLargeCuts: "Apply Cuts"
        case .openSpeechSettings: "Open Settings"
        case .chooseExportLocation: "Choose Location"
        }
    }
}
