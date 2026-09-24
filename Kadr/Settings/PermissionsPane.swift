import SwiftUI

/// Live TCC recovery for people who skipped onboarding (docs/03 §8.2).
struct PermissionsPane: View {
    @State private var tracker = AppPermissionTracker()
    /// What each grant was when the pane opened, so a grant that flips to allowed while
    /// it is open can offer the relaunch macOS needs before it applies (docs/17 T-SH-4).
    @State private var baseline: [AppPermission: AppPermissionStatus]?

    /// Grants that arrived while this process was running and attach only to a new one.
    static func grantsNeedingReopen(
        before: [AppPermission: AppPermissionStatus],
        now: [AppPermission: AppPermissionStatus]
    ) -> [AppPermission] {
        AppPermission.allCases.filter { permission in
            permission.mayNeedRelaunch
                && before[permission] != .allowed
                && now[permission] == .allowed
        }
    }

    private var grantsNeedingReopen: [AppPermission] {
        guard let baseline else { return [] }
        return Self.grantsNeedingReopen(before: baseline, now: tracker.statuses)
    }

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
                            showsRelaunchGuidance: tracker.relaunchGuidanceOwner == permission,
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

            if !grantsNeedingReopen.isEmpty {
                Section {
                    Button("Quit & Reopen Kadr") {
                        AppDelegate.shared.relaunchForNewGrant()
                    }
                    .keyboardShortcut(.defaultAction)
                } footer: {
                    Text(
                        "macOS applies \(grantsNeedingReopen.map(\.title).formatted(.list(type: .and))) "
                            + "the next time Kadr opens."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Check Again") { tracker.refresh() }
                    .disabled(tracker.requesting != nil)
            }
        }
        .settingsFormChrome()
        .onAppear {
            tracker.refresh()
            if baseline == nil {
                baseline = tracker.statuses
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tracker.refresh()
        }
    }
}
