import AppKit
import Carbon.HIToolbox
import os
import OverlayKit
import Shared

/// Counts down before a capture, showing the badge from docs/03 §1.5.
///
/// Named for what it does rather than the setting that drives it, so it does not
/// collide with `SettingsKit.SelfTimer`, which is the stored preference.
///
/// The countdown is a cancellable `Task`, not a repeating timer: it exists only while a
/// capture is pending, so the agent keeps its zero-timers-at-idle promise (PRD §8).
@MainActor
final class CaptureCountdown {
    private let panel = CountdownPanel()
    private let logger = KadrLog.logger(.capture)
    private var task: Task<Void, Never>?
    private let escape = CountdownEscape()

    /// Seconds still showing, or 0 when nothing is counting.
    private(set) var remainingSeconds = 0
    /// Fired each time the number changes, so the recording bar can tick with the badge.
    var onTick: (@MainActor (Int) -> Void)?
    /// Fired when the user calls the countdown off, so the caller can unwind its own
    /// state before `cancel()` drops the badge (docs/14 UX-17A).
    var onCancel: (@MainActor () -> Void)?
    /// Fired when the badge appears and again when it goes away, so the menu-bar icon can
    /// follow the capture-armed state (docs/14 UX-08A).
    var onRunningChanged: (@MainActor (Bool) -> Void)?

    var isRunning: Bool {
        task != nil
    }

    /// Runs the countdown, then calls `perform`. Returns immediately.
    ///
    /// With zero seconds the work runs straight away and no badge appears — the timer
    /// being off must not add a frame of delay to every capture.
    ///
    /// - Parameters:
    ///   - screen: the screen being captured, when the caller knows it.
    ///   - displayID: the display being captured, when only its ID is to hand. The badge
    ///     has to appear on the display in the shot, never on whichever screen AppKit
    ///     happens to call main (docs/14 UX-17A).
    func run(
        seconds: Int,
        placement: CountdownPlacement = .corner,
        screen: NSScreen? = nil,
        displayID: CGDirectDisplayID? = nil,
        perform: @escaping @MainActor () -> Void
    ) {
        cancel()

        guard seconds > 0 else {
            perform()
            return
        }

        let screen = Self.resolveScreen(screen: screen, displayID: displayID)
        escape.start { [weak self] in self?.cancelFromEscape() }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                escape.stop()
                panel.dismiss()
                task = nil
                onRunningChanged?(false)
            }

            for remaining in stride(from: seconds, to: 0, by: -1) {
                tick(remaining)
                if let screen {
                    panel.show(on: screen, seconds: remaining, placement: placement)
                }
                announce(remaining)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    logger.info("Self-timer cancelled")
                    return
                }
            }

            guard !Task.isCancelled else { return }
            // The badge goes before the capture, so it cannot appear in the shot even if
            // window exclusion were to fail.
            panel.dismiss()
            perform()
        }
        onRunningChanged?(true)
    }

    /// Which screen the badge belongs on, in the order a caller can actually be sure of.
    ///
    /// Split out so the rule can be tested without opening a panel: an explicit screen
    /// wins, then the screen carrying the display being captured, then the screen the
    /// pointer is on — which is where a user who pressed a hotkey is looking.
    static func resolveScreen(screen: NSScreen?, displayID: CGDirectDisplayID?) -> NSScreen? {
        if let screen {
            return screen
        }
        if let displayID {
            if let match = NSScreen.screens.first(where: { ScreenDescriptor($0)?.displayID == displayID }) {
                return match
            }
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.screens.first
    }

    /// Called off before it fires.
    ///
    /// Escape is one way in (see `CountdownEscape`); pressing the same capture shortcut
    /// again is the other, and remains so — the shortcut is already in the user's hands
    /// and it is what the recording path documents.
    func cancel() {
        let wasRunning = task != nil
        escape.stop()
        task?.cancel()
        task = nil
        remainingSeconds = 0
        panel.dismiss()
        if wasRunning {
            onRunningChanged?(false)
        }
    }

    /// Escape during the countdown: the owner unwinds first, because `cancel()` is what
    /// its own teardown calls and it has to still see a running countdown.
    private func cancelFromEscape() {
        guard isRunning else { return }
        logger.info("Self-timer cancelled with Escape")
        let onCancel = onCancel
        self.onCancel = nil
        // The owner first: its own teardown calls `cancel()`, and it has to still see a
        // running countdown to know there is one. `cancel()` is idempotent.
        onCancel?()
        cancel()
        // Cleared only for the call, so a re-entrant Escape cannot run it twice. The owner
        // sets it once, and the next countdown's Escape must still reach it (T-CAP-12).
        if self.onCancel == nil {
            self.onCancel = onCancel
        }
    }

    private func tick(_ remaining: Int) {
        remainingSeconds = remaining
        onTick?(remaining)
    }

    /// Speaks each number, so a VoiceOver user knows how long they have (docs/14 UX-17B).
    private func announce(_ remaining: Int) {
        guard let element = panel.accessibilityElement else { return }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(remaining)",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

/// Escape-to-cancel for the countdown, without an Accessibility grant (docs/14 UX-17A).
///
/// The badge is a non-activating panel in an accessory app, so it never becomes key and a
/// plain responder never sees the key. A global `NSEvent` monitor would need an
/// Accessibility grant this feature has no other reason to ask for. Carbon's
/// `RegisterEventHotKey` needs none, and it is registered only for the two or three
/// seconds the number is on screen.
///
/// The local monitor is the backup for the case where Kadr itself is frontmost, where a
/// hot key registration can be consumed by the key window before the dispatcher sees it.
@MainActor
private final class CountdownEscape {
    /// `KDRE`, so this registration cannot collide with anything else in the process.
    fileprivate static let signature = OSType(0x4B44_5245)

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var monitor: Any?
    private var onEscape: (@MainActor () -> Void)?

    func start(onEscape: @escaping @MainActor () -> Void) {
        stop()
        self.onEscape = onEscape
        installHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            MainActor.assumeIsolated { self?.fire() }
            return nil
        }
    }

    func stop() {
        onEscape = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private func fire() {
        let onEscape = onEscape
        self.onEscape = nil
        onEscape?()
    }

    private func installHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                // Another registration's key (`TransientHotKeys`): not ours to answer.
                guard status == noErr, hotKeyID.signature == CountdownEscape.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                // The Carbon dispatcher runs on the main run loop, which is the main actor.
                let escape = MainActor.assumeIsolated {
                    Unmanaged<CountdownEscape>.fromOpaque(userData).takeUnretainedValue()
                }
                // Deferred by one turn: cancelling tears this very handler down, and
                // Carbon is being asked to unregister a handler it is still inside.
                Task { @MainActor in escape.fire() }
                return noErr
            },
            1,
            &eventType,
            context,
            &handler
        )

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            id,
            GetEventDispatcherTarget(),
            0,
            &hotKey
        )
    }
}
