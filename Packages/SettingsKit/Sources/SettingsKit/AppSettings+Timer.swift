import Foundation

public extension AppSettings {
    /// The last typed timer value. Picking a preset switches the custom value off but keeps
    /// it here, so the island's timer menu can still offer it (docs/17 T-CAP-12).
    ///
    /// Read straight from the store rather than observed: the menu reads it as it opens.
    /// A custom value that is on counts as remembered.
    var rememberedCustomTimerSeconds: Int {
        get { max(store[SettingKeys.rememberedCustomTimerSeconds], customTimerSeconds) }
        set { store[SettingKeys.rememberedCustomTimerSeconds] = max(0, newValue) }
    }

    /// Turns the custom timer off for a preset, remembering its value first.
    func selectPresetTimer(_ timer: SelfTimer) {
        if customTimerSeconds > 0 {
            rememberedCustomTimerSeconds = customTimerSeconds
        }
        customTimerSeconds = 0
        selfTimer = timer
    }
}
