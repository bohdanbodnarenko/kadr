import AppKit

extension StatusItemController {
    /// Shared with onboarding's "finish later" copy, which names this row (docs/17 T-SH-4).
    static let finishSetupTitle = String(localized: "Finish Setup…")

    /// Settings and Quit, plus setup only while something required is missing.
    ///
    /// "Setup & Permissions…" and "Check for Updates…" used to be permanent rows. The first
    /// matters only until Screen Recording is granted — after that Settings ▸ Permissions is
    /// the recovery path — so it shows only while it would help. Updates live in
    /// Settings ▸ Updates, which already has Check Now.
    func addApplicationItems(to menu: NSMenu) {
        let extras = additionalItems()
        if !extras.isEmpty {
            Self.addGroupSeparator(to: menu)
            let submenu = NSMenu()
            for item in extras {
                submenu.addItem(item)
            }
            let debug = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
            debug.submenu = submenu
            menu.addItem(debug)
        }

        Self.addGroupSeparator(to: menu)

        if isSetupNeeded {
            let onboardingItem = NSMenuItem(
                title: Self.finishSetupTitle,
                action: #selector(didSelectOnboarding),
                keyEquivalent: ""
            )
            onboardingItem.target = self
            onboardingItem.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "Needs attention"
            )
            menu.addItem(onboardingItem)
        }

        if let version = availableUpdate() {
            // A background check found this and Kadr chose not to interrupt with a window;
            // this row is where it waits (docs/17 T-REL-4, Sparkle's gentle reminders).
            let update = NSMenuItem(
                title: String(localized: "Update to \(version)…"),
                action: #selector(didSelectInstallUpdate),
                keyEquivalent: ""
            )
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            menu.addItem(update)
        }

        if showsTesterItems {
            // Only with ⌥ held: testers are told where to find these, and nobody else
            // needs two more rows every time they open the menu (docs/17 T-DIAG-1).
            let export = NSMenuItem(
                title: String(localized: "Export Diagnostics…"),
                action: #selector(didSelectExportDiagnostics),
                keyEquivalent: ""
            )
            export.target = self
            menu.addItem(export)
            let report = NSMenuItem(
                title: String(localized: "Report a Problem…"),
                action: #selector(didSelectReportProblem),
                keyEquivalent: ""
            )
            report.target = self
            menu.addItem(report)
        }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(didSelectSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Kadr", action: #selector(didSelectQuit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc
    func didSelectInstallUpdate() {
        installUpdate()
    }

    @objc
    func didSelectExportDiagnostics() {
        exportDiagnostics()
    }

    @objc
    func didSelectReportProblem() {
        reportProblem()
    }
}
