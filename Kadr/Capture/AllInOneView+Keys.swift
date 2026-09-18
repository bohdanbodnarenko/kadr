import SwiftUI

extension AllInOneMode {
    /// The letter shown in the mode's hover pill.
    var keyCaption: String {
        String(shortcut).uppercased()
    }
}

extension AllInOneView {
    /// GIF, scrolling, text and colour on a narrow screen, each with its key.
    var overflowMenu: some View {
        Menu {
            ForEach(Self.overflowModes, id: \.self) { mode in
                Button(mode.title) { model.pick(mode) }
                    .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: [])
            }
        } label: {
            RecordingBarIcon(symbol: "ellipsis.circle")
        }
        .recordingBarMenu(tooltip: "More capture modes")
        .accessibilityLabel("More capture modes")
    }

    /// The utilities, each with the single key that runs it while the island is open.
    var toolsMenu: some View {
        Menu {
            ForEach(Array(AllInOneTool.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider()
                }
                ForEach(group, id: \.self) { tool in
                    Button {
                        model.use(tool)
                    } label: {
                        Label(toolTitle(tool), systemImage: tool.symbol)
                    }
                    .keyboardShortcut(KeyEquivalent(tool.shortcut), modifiers: [])
                }
            }
        } label: {
            RecordingBarIcon(symbol: "wrench.and.screwdriver")
        }
        .recordingBarMenu(tooltip: "Tools")
        .accessibilityLabel("Tools")
    }

    private func toolTitle(_ tool: AllInOneTool) -> String {
        if tool == .desktopIcons, model.desktopIconsHidden() {
            return KadrText.string("Show Desktop Icons")
        }
        return tool.title
    }
}
