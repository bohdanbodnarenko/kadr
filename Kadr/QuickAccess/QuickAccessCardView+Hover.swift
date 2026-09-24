import SettingsKit
import SwiftUI

extension QuickAccessCardView {
    /// What hover adds to the picture: a soft veil, the capture's size, Hide, and one bar of
    /// actions — the shape of the macOS screenshot thumbnail, with its daily actions on it.
    ///
    /// The veil takes no clicks, so a hovered card is still dragged by its picture. The
    /// controls sit above the drag surface and take their own.
    var hoverChrome: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.34), location: 0),
                    .init(color: .black.opacity(0.08), location: 0.42),
                    .init(color: .black.opacity(0.14), location: 0.62),
                    .init(color: .black.opacity(0.46), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 5) {
                    corner(.topLeading)
                    // Trash sits at the opposite corner from Hide. Five points apart, a
                    // slightly-off click on Hide threw the capture away (docs/17 T-OUT-7).
                    if showsTrashButton {
                        circleButton("Move to Trash", systemImage: "trash", label: "Move capture to Trash") {
                            actions.delete()
                        }
                    }
                    details
                    Spacer(minLength: 0)
                    corner(.topTrailing)
                    // Hide, not delete. The file stays where the save policy put it (docs/03 §2).
                    circleButton("Hide — the file stays", systemImage: "xmark", label: "Hide card") {
                        actions.dismiss()
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 5) {
                    corner(.bottomLeading)
                    Spacer(minLength: 0)
                    actionBar
                    Spacer(minLength: 0)
                    corner(.bottomTrailing)
                }
            }
            .padding(Self.chromeInset)
        }
        .environment(\.colorScheme, .dark)
    }

    /// One bar on the picture. Anything past what fits is More, never a second row.
    @ViewBuilder
    private var actionBar: some View {
        let row = layout.actions(in: .column, for: item.captureKind)
        let split = Self.splitActions(row, width: width - Self.barPadding * 2)
        if !split.visible.isEmpty || !split.overflow.isEmpty {
            HStack(spacing: Self.actionSpacing) {
                ForEach(split.visible, id: \.self) { action in
                    button(for: action)
                }
                if !split.overflow.isEmpty {
                    moreMenu(split.overflow)
                }
            }
            .padding(Self.barPadding)
            .background(Capsule().fill(CardGlass.fill))
            .overlay(Capsule().strokeBorder(CardGlass.edge, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        }
    }

    static var barPadding: CGFloat {
        3
    }

    private func moreMenu(_ actions: [CardAction]) -> some View {
        Menu {
            ForEach(actions, id: \.self) { cardAction in
                overflowItem(cardAction)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CardBarButtonStyle())
        .fixedSize()
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

    private func circleButton(
        _ help: String,
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(CardCircleButtonStyle())
        .help(help)
        .accessibilityLabel(label)
    }

    /// The layout's corner actions (docs/09 U2.3): one round control each, in its corner.
    private func corner(_ slot: CardSlot) -> some View {
        ForEach(layout.actions(in: slot, for: item.captureKind), id: \.self) { cardAction in
            cornerButton(for: cardAction)
        }
    }

    @ViewBuilder
    private func cornerButton(for cardAction: CardAction) -> some View {
        let style = CardCircleButtonStyle(diameter: 26, glyphSize: 11)
        switch cardAction {
        case .share:
            ShareLink(item: item.fileURL) {
                Image(systemName: cardAction.systemImage)
            }
            .buttonStyle(style)
            .help("Share")
            .accessibilityLabel("Share \(item.filename)")
        default:
            Button {
                perform(cardAction)
            } label: {
                Image(systemName: cardAction.systemImage)
            }
            .buttonStyle(style)
            .help(cardAction.title)
            .accessibilityLabel(cardAction.title)
        }
    }

    @ViewBuilder
    private func button(for cardAction: CardAction) -> some View {
        switch cardAction {
        case .share:
            // Its own case: `NSSharingServicePicker` needs the button's frame to point at.
            ShareLink(item: item.fileURL) {
                Image(systemName: cardAction.systemImage)
            }
            .buttonStyle(CardBarButtonStyle())
            .help("Share")
            .accessibilityLabel("Share \(item.filename)")
        default:
            Button {
                perform(cardAction)
            } label: {
                Image(systemName: cardAction.systemImage)
            }
            .buttonStyle(CardBarButtonStyle())
            .help(cardAction.title)
            .accessibilityLabel(cardAction.title)
        }
    }

    func perform(_ cardAction: CardAction) {
        if let reason = actions.unavailableReason(cardAction) {
            actions.reportUnavailable(reason)
            return
        }
        handler(for: cardAction)()
    }

    /// Share is absent on purpose — it is drawn by its own case above.
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
}
