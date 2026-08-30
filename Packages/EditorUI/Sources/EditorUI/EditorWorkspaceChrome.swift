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
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .fixedSize()
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
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .fixedSize()
            .help("Size in pixels")
    }
}
