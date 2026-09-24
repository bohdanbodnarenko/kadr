import AutomationKit
import SettingsKit
import SwiftUI

/// Sidebar selection for the Settings window. Owned by `SettingsWindowController`
/// so `kadr open-settings --tab` can change panes without rebuilding the tree.
@MainActor
@Observable
final class SettingsNavigation {
    var selectedTab: SettingsTab
    /// Mirrors the split view so View ▸ Show/Hide Sidebar can name the current state.
    var isSidebarHidden = false

    init(selectedTab: SettingsTab) {
        self.selectedTab = selectedTab
    }
}

/// The Settings window's content (docs/03 §8.3).
///
/// Sidebar + detail, not `TabView`: macOS 26 needs an `NSToolbar` (the back/forward
/// items force one) and a split view so liquid-glass chrome can show through.
struct SettingsView: View {
    let settings: AppSettings
    let loginItem: LoginItemController
    var history: HistoryController?
    @Bindable var navigation: SettingsNavigation

    @State private var navigationHistory: [SettingsTab] = []
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false
    /// Real state, not `.constant(.all)`: the system sidebar toggle writes here, and a
    /// constant binding made it a control that did nothing (docs/14 UX-09). Width and
    /// visibility persist through AppKit's frame autosave on the window, so there is no
    /// `AppStorage` key to keep in step with it.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebarView(selectedTab: $navigation.selectedTab)
                .navigationSplitViewColumnWidth(
                    min: SettingsWindowGeometry.sidebarMinimumWidth,
                    ideal: SettingsWindowGeometry.sidebarIdealWidth,
                    max: SettingsWindowGeometry.sidebarMaximumWidth
                )
        } detail: {
            SettingsDetailView(
                tab: navigation.selectedTab,
                settings: settings,
                loginItem: loginItem,
                history: history
            )
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsWindowGeometry.minimumWidth,
            minHeight: SettingsWindowGeometry.minimumHeight
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                .accessibilityLabel(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!canGoBack)
                .help("Back")
                .accessibilityLabel("Back")

                Button {
                    goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!canGoForward)
                .help("Forward")
                .accessibilityLabel("Forward")
            }
        }
        .kadrLayoutDirection()
        .onAppear {
            if navigationHistory.isEmpty {
                navigationHistory = [navigation.selectedTab]
            }
            publishSidebarVisibility()
        }
        .onChange(of: navigation.selectedTab) { _, _ in
            recordNavigation()
        }
        .onChange(of: columnVisibility) { _, _ in
            publishSidebarVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kadrToggleSettingsSidebar)) { _ in
            toggleSidebar()
        }
    }

    private var canGoBack: Bool {
        historyIndex > 0
    }

    private var canGoForward: Bool {
        historyIndex < navigationHistory.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        isHistoryNavigation = true
        historyIndex -= 1
        navigation.selectedTab = navigationHistory[historyIndex]
        Task { @MainActor in
            isHistoryNavigation = false
        }
    }

    private func goForward() {
        guard canGoForward else { return }
        isHistoryNavigation = true
        historyIndex += 1
        navigation.selectedTab = navigationHistory[historyIndex]
        Task { @MainActor in
            isHistoryNavigation = false
        }
    }

    private func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    private func publishSidebarVisibility() {
        navigation.isSidebarHidden = columnVisibility == .detailOnly
    }

    private func recordNavigation() {
        guard !isHistoryNavigation else { return }
        let tab = navigation.selectedTab
        if navigationHistory.isEmpty {
            navigationHistory = [tab]
            historyIndex = 0
            return
        }
        if navigationHistory[historyIndex] == tab {
            return
        }
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
        }
        navigationHistory.append(tab)
        historyIndex = navigationHistory.count - 1
    }
}

// MARK: - Sidebar

private struct SettingsSidebarView: View {
    @Binding var selectedTab: SettingsTab

    /// Observable, so the warning appears and clears as shortcuts change (docs/17 T-SH-7).
    private var hotkeyHealth: HotkeyHealth? {
        AppDelegate.shared.hotkeyCenter?.health
    }

    private var selection: Binding<SettingsTab?> {
        Binding(
            get: { selectedTab },
            set: {
                if let tab = $0 {
                    selectedTab = tab
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            ForEach(SettingsTab.allCases) { tab in
                HStack {
                    Label(tab.title, systemImage: tab.systemImage)
                    if tab == .shortcuts, hotkeyHealth?.hasConflicts == true {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("A shortcut could not be registered")
                            .accessibilityLabel("A shortcut could not be registered")
                    }
                }
                .tag(tab)
            }

            SettingsSidebarFooter()
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyleSoftIfAvailable()
        .navigationTitle("Settings")
    }
}

private struct SettingsSidebarFooter: View {
    private var versionText: String {
        "Version \(BuildIdentity.current.displayString)"
    }

    var body: some View {
        Text(versionText)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .fontDesign(.monospaced)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
    }
}

// MARK: - Detail

private struct SettingsDetailView: View {
    let tab: SettingsTab
    let settings: AppSettings
    let loginItem: LoginItemController
    var history: HistoryController?

    var body: some View {
        Group {
            switch tab {
            case .general:
                GeneralPane(settings: settings, loginItem: loginItem)
            case .permissions:
                PermissionsPane()
            case .overlay:
                OverlayPane(settings: settings)
            case .capture:
                CapturePane(settings: settings)
            case .recording:
                RecordingPane(settings: settings)
            case .history:
                HistoryPane(settings: settings, history: history)
            case .shortcuts:
                ShortcutsPane(health: AppDelegate.shared.hotkeyCenter?.health)
            case .updates:
                UpdatesPane(updater: .shared, copyDiagnosticSummary: { AppDelegate.shared.copyDiagnosticSummary() })
            case .advanced:
                AdvancedPane(settings: settings)
            }
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Presentation

extension SettingsTab {
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .permissions: String(localized: "Permissions")
        case .overlay: String(localized: "Overlay")
        case .capture: String(localized: "Capture")
        case .recording: String(localized: "Recording")
        case .history: String(localized: "History")
        case .shortcuts: String(localized: "Shortcuts")
        case .updates: String(localized: "Updates")
        case .advanced: String(localized: "Advanced")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "lock.shield"
        case .overlay: "rectangle.stack"
        case .capture: "camera.viewfinder"
        case .recording: "record.circle"
        case .history: "clock"
        case .shortcuts: "keyboard"
        case .updates: "arrow.down.circle"
        case .advanced: "terminal"
        }
    }
}

extension View {
    /// Grouped form chrome that lets liquid-glass window material show through.
    func settingsFormChrome() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
    }

    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
