import Carbon.HIToolbox
import Foundation
import os

/// A system-wide keyboard shortcut.
///
/// This deliberately does not reuse Klik's own event tap. The tap is
/// `.listenOnly`, which means it can watch keystrokes but cannot swallow them --
/// the shortcut would fire *and* still reach whatever app you were typing in.
/// `RegisterEventHotKey` claims the combination properly, so nothing else sees it.
final class GlobalHotKey {

    var onPress: (() -> Void)?

    private static let log = Logger(subsystem: "com.klik.Klik", category: "hotkey")
    /// Carbon hands the callback an id, not a context pointer, so registered
    /// instances are looked up here. Only ever touched on the main thread.
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1

    private var identifier: UInt32 = 0
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Control-Option-Command-M. Obscure enough that almost nothing else claims it.
    static let muteKeyCode = UInt32(kVK_ANSI_M)
    static let muteModifiers = UInt32(controlKey | optionKey | cmdKey)
    static let muteDescription = "⌃⌥⌘M"

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        identifier = Self.nextID
        Self.nextID += 1
        Self.registry[identifier] = self

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                guard status == noErr else { return status }
                GlobalHotKey.registry[pressed.id]?.onPress?()
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &handlerRef
        )
        guard handlerStatus == noErr else {
            Self.log.error("Could not install hot key handler (\(handlerStatus))")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4B4C_4B31), id: identifier)  // 'KLK1'
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status != noErr {
            // Almost always means another app already owns the combination.
            Self.log.error("Could not register hot key (\(status))")
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        Self.registry[identifier] = nil
    }

    deinit { unregister() }
}
