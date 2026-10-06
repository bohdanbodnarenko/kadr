import Foundation

/// Where the recording bar and the camera bubble were last put (docs/18 REC P3).
///
/// They used to live in static variables and were forgotten on every relaunch, so a bubble
/// moved off the face of the slides came back over them the next morning. Points are stored
/// as `NSStringFromPoint` text; empty means "never placed".
public extension AppSettings {
    var recordingBarOrigin: String {
        get {
            access(keyPath: \.recordingBarOrigin)
            return store[SettingKeys.recordingBarOrigin]
        }
        set {
            withMutation(keyPath: \.recordingBarOrigin) {
                store[SettingKeys.recordingBarOrigin] = newValue
            }
        }
    }

    var cameraBubbleOrigin: String {
        get {
            access(keyPath: \.cameraBubbleOrigin)
            return store[SettingKeys.cameraBubbleOrigin]
        }
        set {
            withMutation(keyPath: \.cameraBubbleOrigin) {
                store[SettingKeys.cameraBubbleOrigin] = newValue
            }
        }
    }

    var cameraBubbleDiameter: Double {
        get {
            access(keyPath: \.cameraBubbleDiameter)
            return store[SettingKeys.cameraBubbleDiameter]
        }
        set {
            withMutation(keyPath: \.cameraBubbleDiameter) {
                store[SettingKeys.cameraBubbleDiameter] = newValue
            }
        }
    }

    var cameraBubbleIsCircular: Bool {
        get {
            access(keyPath: \.cameraBubbleIsCircular)
            return store[SettingKeys.cameraBubbleIsCircular]
        }
        set {
            withMutation(keyPath: \.cameraBubbleIsCircular) {
                store[SettingKeys.cameraBubbleIsCircular] = newValue
            }
        }
    }

    /// Back to "never placed", with Reset All Settings.
    internal func resetPlacement() {
        recordingBarOrigin = SettingKeys.recordingBarOrigin.defaultValue
        cameraBubbleOrigin = SettingKeys.cameraBubbleOrigin.defaultValue
        cameraBubbleDiameter = SettingKeys.cameraBubbleDiameter.defaultValue
        cameraBubbleIsCircular = SettingKeys.cameraBubbleIsCircular.defaultValue
    }
}
