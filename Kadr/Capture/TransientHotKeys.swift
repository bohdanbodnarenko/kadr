import AppKit
import Carbon.HIToolbox

/// A handful of keys that work while a non-activating capture surface is up, whatever app
/// is frontmost (docs/17 T-CAP-10).
///
/// The same approach as the countdown's Escape (`CountdownEscape`): Carbon's
/// `RegisterEventHotKey` needs no Accessibility grant, and it is registered only for as
/// long as the surface is on screen, so Return and Escape are taken from the user's app for
/// exactly the moment they mean "start" and "cancel" here. A local monitor covers the case
/// where Kadr itself is frontmost, where the key window can consume the hot key first.
@MainActor
final class TransientHotKeys {
    struct Key: Hashable {
        let keyCode: UInt32
        /// Carbon modifier mask (`optionKey`, `cmdKey`…), 0 for none.
        let carbonModifiers: UInt32

        static let escape = Key(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)
        static let returnKey = Key(keyCode: UInt32(kVK_Return), carbonModifiers: 0)
        static let enter = Key(keyCode: UInt32(kVK_ANSI_KeypadEnter), carbonModifiers: 0)
        static let optionReturn = Key(keyCode: UInt32(kVK_Return), carbonModifiers: UInt32(optionKey))

        /// The key an `NSEvent` is, in the same terms, for the local monitor.
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: UInt32 = 0
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
        }

        init(keyCode: UInt32, carbonModifiers: UInt32) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
        }
    }

    /// `KDRS`: distinct from the countdown's `KDRE`, so each handler answers only its own.
    private static let signature = OSType(0x4B44_5253)

    private var actions: [UInt32: (key: Key, action: @MainActor () -> Void)] = [:]
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var monitor: Any?

    var isActive: Bool {
        handler != nil || monitor != nil
    }

    func start(_ bindings: [Key: @MainActor () -> Void]) {
        stop()
        var next: UInt32 = 1
        for (key, action) in bindings {
            actions[next] = (key, action)
            next += 1
        }
        installHandler()
        for (id, entry) in actions {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(
                entry.key.keyCode,
                entry.key.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if let ref {
                hotKeys.append(ref)
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let key = Key(event: event) else { return event }
            let handled = MainActor.assumeIsolated { self?.fire(key: key) ?? false }
            return handled ? nil : event
        }
    }

    func stop() {
        actions = [:]
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        for ref in hotKeys {
            UnregisterEventHotKey(ref)
        }
        hotKeys = []
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private func fire(key: Key) -> Bool {
        guard let entry = actions.values.first(where: { $0.key == key }) else { return false }
        entry.action()
        return true
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?.action()
    }

    private func installHandler() {
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
                // Someone else's hot key (the countdown's Escape, a capture shortcut):
                // pass it on untouched.
                guard status == noErr, hotKeyID.signature == TransientHotKeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let keys = MainActor.assumeIsolated {
                    Unmanaged<TransientHotKeys>.fromOpaque(userData).takeUnretainedValue()
                }
                let id = hotKeyID.id
                // Deferred by one turn: the action usually tears this very handler down.
                Task { @MainActor in keys.fire(id: id) }
                return noErr
            },
            1,
            &eventType,
            context,
            &handler
        )
    }
}
