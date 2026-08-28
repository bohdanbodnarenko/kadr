import SettingsKit
import SwiftUI

/// What happens after each kind of capture (docs/09 U2.2).
///
/// A grid of checkboxes rather than a picker, because the options compose: copying and
/// saving are not alternatives, and the old single choice made people pick the one enum
/// case that happened to mean both. Two rows, because the useful answers genuinely differ —
/// nobody wants a two-minute recording on their clipboard.
struct AfterCaptureMatrixEditor: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(CaptureKind.allCases, id: \.self) { kind in
                row(for: kind)
            }
        }
    }

    private func row(for kind: CaptureKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title)
                .font(.subheadline.weight(.medium))

            ForEach(applicableActions(for: kind), id: \.rawValue) { action in
                Toggle(action.title, isOn: binding(kind, action))
                    .toggleStyle(.checkbox)
            }
        }
    }

    /// Only the actions that mean something for this kind: annotating a movie is a button
    /// that does nothing, which is the failure the review found on the cards (docs/07 M8).
    private func applicableActions(for kind: CaptureKind) -> [AfterCaptureActions] {
        AfterCaptureActions.allCases.filter { $0.applies(to: kind) }
    }

    private func binding(_ kind: CaptureKind, _ action: AfterCaptureActions) -> Binding<Bool> {
        Binding(
            get: { settings.afterCapture[kind].contains(action) },
            set: { isOn in
                var matrix = settings.afterCapture
                var actions = matrix[kind]
                if isOn {
                    actions.insert(action)
                } else {
                    actions.remove(action)
                }
                matrix[kind] = actions
                settings.afterCapture = matrix
            }
        )
    }
}
