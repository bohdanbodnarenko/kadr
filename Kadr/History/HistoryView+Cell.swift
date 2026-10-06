import ControlKit
import HistoryKit
import SwiftUI

struct HistoryCell: View {
    let record: HistoryRecord
    let title: String
    let cachedImage: CGImage?
    let loadImage: () async -> CGImage?
    let isSelected: Bool
    let isFocused: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
                if record.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                // A project looks like the capture it is built on, so it needs a badge to
                // say that opening it reopens an editing session (docs/06 M24).
                if record.kind == .project {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: KadrRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: KadrRadius.large)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 3 : 1
                    )
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: KadrRadius.large)
                        .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1, antialiased: true)
                        .padding(KadrSpace.xxs)
                }
            }

            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .task(id: record.id) {
            if let cachedImage {
                image = cachedImage
                return
            }
            image = await loadImage()
        }
    }

    private var subtitle: String {
        var parts: [String] = [record.capturedAt.formatted(.relative(presentation: .named))]
        if let app = record.applicationName, !app.isEmpty {
            parts.append(app)
        }
        parts.append(ByteCountFormatter.string(fromByteCount: record.byteSize, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        let kind = record.kind.title
        let dimensions = "\(record.width) × \(record.height)"
        let timestamp = record.capturedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(kind), \(title), \(dimensions), \(timestamp)"
    }
}
