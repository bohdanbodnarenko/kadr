import Foundation

/// Parity settings kept off the main `AppSettings` type body (docs/16).
public extension AppSettings {
    var showsMenuBarIcon: Bool {
        get {
            access(keyPath: \.showsMenuBarIcon)
            return store[SettingKeys.showsMenuBarIcon]
        }
        set {
            withMutation(keyPath: \.showsMenuBarIcon) {
                store[SettingKeys.showsMenuBarIcon] = newValue
            }
        }
    }

    var fullscreenTarget: FullscreenTarget {
        get {
            access(keyPath: \.fullscreenTarget)
            return store[SettingKeys.fullscreenTarget]
        }
        set {
            withMutation(keyPath: \.fullscreenTarget) {
                store[SettingKeys.fullscreenTarget] = newValue
            }
        }
    }

    var playsCaptureSound: Bool {
        get {
            access(keyPath: \.playsCaptureSound)
            return store[SettingKeys.playsCaptureSound]
        }
        set {
            withMutation(keyPath: \.playsCaptureSound) {
                store[SettingKeys.playsCaptureSound] = newValue
            }
        }
    }

    var includesOverlaysInCaptures: Bool {
        get {
            access(keyPath: \.includesOverlaysInCaptures)
            return store[SettingKeys.includesOverlaysInCaptures]
        }
        set {
            withMutation(keyPath: \.includesOverlaysInCaptures) {
                store[SettingKeys.includesOverlaysInCaptures] = newValue
            }
        }
    }

    var lossyQuality: Double {
        get {
            access(keyPath: \.lossyQuality)
            return min(max(store[SettingKeys.lossyQuality], 0.1), 1)
        }
        set {
            withMutation(keyPath: \.lossyQuality) {
                store[SettingKeys.lossyQuality] = min(max(newValue, 0.1), 1)
            }
        }
    }

    /// Where captures are written. Falls back to the Desktop until the user picks a folder.
    var saveFolder: URL {
        guard !saveFolderPath.isEmpty else { return Self.defaultSaveFolder }
        return URL(fileURLWithPath: saveFolderPath, isDirectory: true)
    }

    static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}
