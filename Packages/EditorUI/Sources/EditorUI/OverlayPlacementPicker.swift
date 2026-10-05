import StudioSession
import SwiftUI

/// Where an overlay sits on the picture: six slots, drawn as the picture (docs/09 U3.4).
///
/// A proportioned frame with the chosen slot filled, rather than six tinted push buttons in
/// two rows. Position is a spatial question, so the control answers it spatially — the same
/// reason the print dialog draws its layout instead of listing it. One accessibility element
/// with a value, not six buttons VoiceOver has to be walked through.
struct OverlayPlacementPicker: View {
    @Binding var selection: OverlayPlacement

    private static let rows: [[OverlayPlacement]] = [
        [.topLeading, .top, .topTrailing],
        [.bottomLeading, .bottom, .bottomTrailing]
    ]

    var body: some View {
        LabeledContent("Position") {
            VStack(spacing: 2) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(row) { slot in
                            cell(slot)
                        }
                    }
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .frame(width: 78, height: 46)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue(Self.spokenName(selection))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Choose which corner or edge the overlay sits on")
        }
    }

    private func cell(_ slot: OverlayPlacement) -> some View {
        let isSelected = slot == selection
        return Button {
            selection = slot
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.spokenName(slot))
        .accessibilityHidden(true)
    }

    /// "Top left", not "Left" — the enum's own title is the column, which only reads as a
    /// position when the row it sits in is visible.
    static func spokenName(_ slot: OverlayPlacement) -> String {
        let row = slot.isTop ? String(localized: "Top") : String(localized: "Bottom")
        let column = switch slot {
        case .topLeading, .bottomLeading: String(localized: "left")
        case .top, .bottom: String(localized: "center")
        case .topTrailing, .bottomTrailing: String(localized: "right")
        }
        return "\(row) \(column)"
    }
}
