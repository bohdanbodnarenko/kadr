import Foundation
import IOKit.ps

/// Whether the machine can afford background work right now (docs/03 §5 P3).
///
/// Kadr's one piece of speculative work is the history text index, and the promise about
/// it is specific: it costs nothing you did not ask for. That means it runs on mains
/// power, outside Low Power Mode, and never on a timer — the agent asks for a pass when
/// something already woke it up, and only then.
public enum PowerState {
    /// Whether the machine is running off mains rather than its battery.
    ///
    /// A desktop with no battery reports AC, which is the right answer for it.
    public static var isOnACPower: Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() else {
            // No power-source information at all: treat it as a desktop rather than
            // refusing to ever index.
            return true
        }
        return (type as String) == kIOPSACPowerValue
    }

    public static var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// The one question callers actually ask.
    public static var allowsBackgroundWork: Bool {
        isOnACPower && !isLowPowerModeEnabled
    }
}
