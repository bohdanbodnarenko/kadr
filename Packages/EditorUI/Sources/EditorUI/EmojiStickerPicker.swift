import SwiftUI

/// The emoji strip the sticker tool places (docs/03 §3 P2).
struct EmojiStickerPicker: View {
    @Binding var selected: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
            ForEach(EmojiSticker.catalog, id: \.self) { emoji in
                Button {
                    selected = emoji
                } label: {
                    Text(emoji)
                        .font(.system(size: 20))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(emoji == selected ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji)
                .accessibilityAddTraits(emoji == selected ? .isSelected : [])
            }
        }
    }
}
