import SwiftUI

/// How long a transcription has been running, beside its progress bar (docs/18 STU-9).
///
/// The bar alone could sit still for minutes on an engine that reports no progress, which
/// reads as a hang. Ticks once a second, and only while it is on screen.
struct TranscriptionElapsed: View {
    @State private var started = Date()

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            Text(Self.label(context.date.timeIntervalSince(started)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(String(localized: "Time elapsed", bundle: .module))
    }

    static func label(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(seconds, 0).rounded(.down))
            .formatted(.time(pattern: .minuteSecond))
    }
}
