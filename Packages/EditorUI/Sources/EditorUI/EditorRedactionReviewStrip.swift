import Shared
import SwiftUI

/// Review strip for auto-redaction: accept / skip / accept all, never silent apply.
struct EditorRedactionReviewStrip: View {
    @Bindable var model: EditorDocumentModel
    var onFind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let error = model.redactionAssistError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            findField
            if !model.redactionCandidates.isEmpty {
                candidateList
            } else if !model.isFindingRedactions, model.redactionAssistError == nil {
                Text("No secrets found. Use the field above to redact matching text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .editorFloatingCard()
    }

    private var header: some View {
        HStack {
            if model.isFindingRedactions {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for secrets…")
            } else {
                Text(title)
                    .font(.headline)
            }
            Spacer()
            Button("Accept All") {
                model.acceptAllRedactions()
            }
            .disabled(model.redactionCandidates.isEmpty)
            .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Dismiss") {
                model.dismissRedactionReview()
            }
        }
    }

    private var title: String {
        let count = model.redactionCandidates.count
        if count == 0 {
            return "Auto-redact"
        }
        if count == 1 {
            return "1 possible secret"
        }
        return "\(count) possible secrets"
    }

    private var findField: some View {
        HStack {
            TextField("Redact all text matching…", text: $model.redactionQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onFind)
            Button("Find", action: onFind)
                .disabled(model.redactionQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
        }
    }

    private var candidateList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.redactionCandidates) { candidate in
                    candidateChip(candidate)
                }
            }
        }
    }

    private func candidateChip(_ candidate: RedactionCandidate) -> some View {
        HStack(spacing: 6) {
            Text(candidate.kind.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(snippet(candidate.text))
                .font(.callout.monospaced())
                .lineLimit(1)
            Button("Accept") {
                model.acceptRedaction(candidate.id)
            }
            .controlSize(.small)
            Button("Skip", role: .cancel) {
                model.skipRedaction(candidate.id)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.orange)
        )
        .help(candidate.text)
    }

    private func snippet(_ text: String) -> String {
        if text.count <= 28 {
            return text
        }
        return String(text.prefix(14)) + "…" + String(text.suffix(10))
    }
}
