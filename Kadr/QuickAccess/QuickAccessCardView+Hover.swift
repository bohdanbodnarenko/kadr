import SettingsKit
import SwiftUI

extension QuickAccessCardView {
    /// A light veil so buttons read, without hiding the capture they are for.
    var hoverChrome: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.45), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 40)
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 56)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    corner(.topLeading)
                    Spacer(minLength: 0)
                    corner(.topTrailing)
                    if showsTrashButton {
                        trashButton
                    }
                    hideButton
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        details
                        HStack(spacing: 4) {
                            corner(.bottomLeading)
                            corner(.bottomTrailing)
                        }
                    }
                    Spacer(minLength: 4)
                    primaryActionRow
                }
            }
            .padding(Self.chromeInset)
        }
    }

    /// One row on the picture. Anything past that is a More menu, not a second row.
    @ViewBuilder
    private var primaryActionRow: some View {
        let column = layout.actions(in: .column, for: item.captureKind)
        let split = Self.splitActions(column, width: width)
        if !split.visible.isEmpty || !split.overflow.isEmpty {
            HStack(spacing: Self.actionSpacing) {
                ForEach(split.visible, id: \.self) { action in
                    button(for: action)
                        .background(.regularMaterial, in: Circle())
                }
                if !split.overflow.isEmpty {
                    moreMenu(split.overflow)
                }
            }
        }
    }

    private func moreMenu(_ actions: [CardAction]) -> some View {
        Menu {
            ForEach(actions, id: \.self) { cardAction in
                overflowItem(cardAction)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: Self.actionButtonSize - 6, height: Self.actionButtonSize - 6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(CardActionButtonStyle())
        .kadrHitTarget(minSize: 20)
        .background(.regularMaterial, in: Circle())
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    @ViewBuilder
    private func overflowItem(_ cardAction: CardAction) -> some View {
        if cardAction == .share {
            ShareLink(item: item.fileURL) {
                Label(cardAction.title, systemImage: cardAction.systemImage)
            }
            .accessibilityLabel("Share \(item.filename)")
        } else {
            Button(cardAction.title, systemImage: cardAction.systemImage) {
                perform(cardAction)
            }
        }
    }

    /// Hide, not delete. The file stays where the save policy put it (docs/03 §2).
    private var hideButton: some View {
        Button(action: actions.dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(CardCloseButtonStyle())
        .kadrHitTarget(minSize: 20)
        .help("Hide — the file stays")
        .accessibilityLabel("Hide card")
    }

    /// Move to Trash when the capture is already on disk (CleanShot §6.2).
    private var trashButton: some View {
        Button(action: actions.delete) {
            Image(systemName: "trash")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(CardCloseButtonStyle())
        .kadrHitTarget(minSize: 20)
        .help("Move to Trash")
        .accessibilityLabel("Delete capture")
    }

    /// The buttons the user's layout asks for, in the order they asked for them
    /// (docs/09 U2.3).
    private func corner(_ slot: CardSlot) -> some View {
        ForEach(layout.actions(in: slot, for: item.captureKind), id: \.self) { action in
            button(for: action)
                .background(.regularMaterial, in: Circle())
        }
    }

    @ViewBuilder
    private func button(for cardAction: CardAction) -> some View {
        switch cardAction {
        case .share:
            ShareLink(item: item.fileURL) {
                Image(systemName: cardAction.systemImage)
                    .frame(width: Self.actionButtonSize - 6, height: Self.actionButtonSize - 6)
            }
            .buttonStyle(CardActionButtonStyle())
            .kadrHitTarget(minSize: 20)
            .help("Share")
            .accessibilityLabel("Share \(item.filename)")
        default:
            action(
                cardAction.title,
                systemImage: cardAction.systemImage,
                action: { perform(cardAction) }
            )
        }
    }

    func perform(_ cardAction: CardAction) {
        if let reason = actions.unavailableReason(cardAction) {
            actions.reportUnavailable(reason)
            return
        }
        handler(for: cardAction)()
    }

    /// Share is absent on purpose — it is drawn by its own case above, because
    /// `NSSharingServicePicker` needs the button's frame to point at.
    private var handlers: [CardAction: () -> Void] {
        [
            .copy: actions.copy,
            .save: actions.save,
            .saveAs: actions.saveAs,
            .annotate: actions.annotate,
            .pin: actions.pin,
            .recognizeText: actions.recognizeText,
            .trim: actions.trim,
            .studio: actions.studio,
            .exportGIF: actions.exportGIF,
            .compress: actions.compress,
            .delete: actions.delete
        ]
    }

    private func handler(for cardAction: CardAction) -> () -> Void {
        handlers[cardAction] ?? {}
    }

    private func action(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: Self.actionButtonSize - 6, height: Self.actionButtonSize - 6)
        }
        .buttonStyle(CardActionButtonStyle())
        .kadrHitTarget(minSize: 20)
        .help(title)
        .accessibilityLabel(title)
    }
}
