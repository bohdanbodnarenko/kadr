import SwiftUI

/// Live TCC recovery for people who skipped onboarding (docs/03 §8.2).
struct PermissionsPane: View {
    @State private var tracker = AppPermissionTracker()

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    ForEach(AppPermission.allCases) { permission in
                        AppPermissionRow(
                            permission: permission,
                            status: tracker.status(permission),
                            attempted: tracker.attempted.contains(permission),
                            isRequesting: tracker.requesting == permission,
                            requestsDisabled: tracker.requesting != nil,
                            errorMessage: tracker.settingsErrorPermission == permission
                                ? tracker.settingsError
                                : nil,
                            request: { Task { await tracker.request(permission) } },
                            openSettings: { tracker.openSettings(permission) }
                        )
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                .listRowBackground(Color.clear)
            } footer: {
                Text(
                    "Screen capture is required for screenshots and recordings. "
                        + "The others stay off until you use the feature they unlock. "
                        + "Access updates when you return to this pane."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Button("Check Again") { tracker.refresh() }
                    .disabled(tracker.requesting != nil)
            }
        }
        .settingsFormChrome()
        .onAppear { tracker.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tracker.refresh()
        }
    }
}
