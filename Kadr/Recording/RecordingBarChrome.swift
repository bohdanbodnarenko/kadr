import SwiftUI

/// Shared chrome for the floating recording bar — picker, countdown and live session
/// all use the same capsule so morphing between them does not look like a different app.
struct RecordingBarBackground: View {
    var body: some View {
        Capsule()
            .fill(.thinMaterial)
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.45),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
            .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
    }
}

struct RecordingBarDivider: View {
    var body: some View {
        Divider().frame(height: 20)
    }
}

/// A quiet round control, sized so it can be hit without aiming.
struct RecordingBarCircleButton: View {
    let symbol: String
    var help: String = ""
    var isOn: Bool = true
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RecordingBarIcon(symbol: symbol, isOn: isOn, tint: tint)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct RecordingBarIcon: View {
    let symbol: String
    var isOn: Bool = true
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint ?? (isOn ? Color.primary : Color.secondary))
            .frame(width: 26, height: 26)
            .contentShape(Circle())
            .background(Circle().fill(Color.primary.opacity(0.07)))
    }
}

/// The red commit control — Skip during countdown, Stop while recording.
struct RecordingBarFilledCircleButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.red))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
