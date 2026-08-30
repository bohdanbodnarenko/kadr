import AppKit
import CoreGraphics
import Foundation
import os
import Shared
import StudioSession

/// Where pointer events come from, in the order the ladder prefers them (docs/09 U3.1).
///
/// Three rungs, and exactly one of them runs. A listen-only `CGEvent` tap is the best
/// source and needs Accessibility; AppKit's global monitors need no permission and see
/// less; a timed sampler sees only position and always works. Which one is live is
/// `TelemetryPolicy`'s decision — this file only knows how to install and remove them.
///
/// Split from the recorder because installing an input source and deciding what to do with
/// an event change for different reasons, and because the recorder was over its budget.
@MainActor
extension PointerTelemetryRecorder {
    /// A listen-only tap. Returns whether it could be created.
    func startEventTap() -> Bool {
        let mask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<PointerTelemetryRecorder>.fromOpaque(context).takeUnretainedValue()
            let location = event.location
            // Straight back out: macOS disables a tap whose callback runs long, and the
            // work belongs on the main actor anyway.
            MainActor.assumeIsolated {
                recorder.handleTapEvent(type: type, at: location)
            }
            // Unmodified, always. A listen-only tap that returned anything else would be
            // editing another app's input.
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.info("No event tap; falling back to monitors")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    /// A `CGEvent`'s location is CoreGraphics' global *display* space — origin top-left —
    /// which is the mirror of the screen space everything downstream expects (docs/11 C1).
    func handleTapEvent(type: CGEventType, at location: CGPoint) {
        let point = DisplayPoint(x: location.x, y: location.y).inScreenSpace(space)
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            recordPointer(at: point)
        case .leftMouseDown:
            recordClick(at: point, button: .left, isDown: true)
        case .leftMouseUp:
            recordClick(at: point, button: .left, isDown: false)
        case .rightMouseDown:
            recordClick(at: point, button: .right, isDown: true)
        case .rightMouseUp:
            recordClick(at: point, button: .right, isDown: false)
        default:
            break
        }
    }

    /// AppKit monitors, which need no permission. Returns whether they were installed.
    func startMonitors() -> Bool {
        let mouse: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp
        ]
        // The event itself is not `Sendable`, so what crosses into the isolated call is
        // the handful of values read from it — which is all the recorder wants anyway.
        let mouseHandler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                self?.handleMonitorEvent(type: type, at: location)
            }
        }
        guard let mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouse,
            handler: mouseHandler
        ) else {
            return false
        }
        monitors.append(mouseMonitor)

        return true
    }

    /// The keyboard, which the tap never carried.
    ///
    /// Installed whichever pointer rung won: the tap's mask has no `keyDown` in it, so a
    /// tap that wins the pointer says nothing about hearing the keyboard (docs/11 S0.2).
    ///
    /// Keystrokes need Accessibility too; without it this simply returns nil and the
    /// sidecar has no captions, which is a smaller loss than no telemetry at all.
    func startKeystrokeMonitor() {
        let keyHandler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let characters = event.charactersIgnoringModifiers
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                self?.recordKeystroke(characters: characters, keyCode: keyCode, flags: flags)
            }
        }
        if let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: keyHandler) {
            monitors.append(keyMonitor)
        }
    }

    /// `NSEvent.mouseLocation` is AppKit's global *screen* space — origin bottom-left —
    /// which is what everything downstream expects, and the mirror of what the tap hands
    /// over. Naming both is the point of the types (docs/11 C1).
    func handleMonitorEvent(type: NSEvent.EventType, at location: CGPoint) {
        let point = ScreenPoint(x: location.x, y: location.y)
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            recordPointer(at: point)
        case .leftMouseDown:
            recordClick(at: point, button: .left, isDown: true)
        case .leftMouseUp:
            recordClick(at: point, button: .left, isDown: false)
        case .rightMouseDown:
            recordClick(at: point, button: .right, isDown: true)
        case .rightMouseUp:
            recordClick(at: point, button: .right, isDown: false)
        default:
            break
        }
    }

    /// The floor: read the pointer on a schedule.
    ///
    /// A `Task` rather than a `Timer`, and only while recording — the agent's zero-timer
    /// rule is about the idle process, and this exists solely between start and stop.
    func startSampler() {
        samplerTask = Task { [weak self] in
            let interval = Duration.seconds(1 / TelemetryPolicy.sampleRate)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, isRecording else { return }
                let location = NSEvent.mouseLocation
                recordPointer(at: ScreenPoint(x: location.x, y: location.y))
            }
        }
    }

    // MARK: - Key mapping

    /// The named keys worth captioning, by virtual key code.
    ///
    /// A table rather than a switch: this is a lookup, and writing it as control flow both
    /// reads as a decision it is not and counts against the complexity budget.
    private static let specialKeyCodes: [UInt16: TelemetryPolicy.SpecialKey] = [
        36: .returnKey,
        76: .enter,
        48: .tab,
        53: .escape,
        51: .delete,
        117: .forwardDelete,
        126: .upArrow,
        125: .downArrow,
        123: .leftArrow,
        124: .rightArrow,
        116: .pageUp,
        121: .pageDown,
        115: .home,
        119: .end,
        49: .space
    ]

    static func specialKey(for keyCode: UInt16) -> TelemetryPolicy.SpecialKey? {
        specialKeyCodes[keyCode]
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> TelemetryPolicy.Modifiers {
        var modifiers = TelemetryPolicy.Modifiers()
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.function) {
            modifiers.insert(.function)
        }
        return modifiers
    }
}
