import AppKit

extension StatusItemController {
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
                title: "Finish Setup…",
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
}
