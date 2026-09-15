import AppKit
import Foundation
import os
import Shared

/// The system Screen Capture sound, loaded on first play (docs/16 X-3).
@MainActor
enum CaptureSound {
    private static var cached: NSSound?
    private static let logger = KadrLog.logger(.capture)

    static func play() {
        if cached == nil {
            cached = load()
        }
        cached?.stop()
        cached?.currentTime = 0
        if cached?.play() != true {
            NSSound.beep()
        }
    }

    static func beep() {
        NSSound.beep()
    }

    private static func load() -> NSSound? {
        let url = URL(
            fileURLWithPath: "/System/Library/Components/CoreAudio.component/"
                + "Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        )
        if let sound = NSSound(contentsOf: url, byReference: true) {
            return sound
        }
        if let grab = NSSound(named: "Grab") {
            return grab
        }
        logger.info("Capture sound is unavailable; captures stay silent")
        return nil
    }
}
