import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// A global keyboard listener built on a CoreGraphics event tap.
///
/// The tap is created with `.listenOnly`, which matters: a listening tap is not
/// in the input path, so a slow callback cannot stall typing system-wide the way
/// a filtering tap can. The callback still runs on this object's own thread and
/// still does as little as possible -- read the key code, hand it over.
///
/// macOS disables a tap that misbehaves or is interrupted, without warning and
/// without stopping the run loop, so both disable notifications are caught and
/// the tap re-enabled.
final class KeyTap {

    /// Virtual key code, whether it was a press, and whether it came from the
    /// system's key-repeat rather than a fresh press.
    var onKey: ((UInt16, Bool, Bool) -> Void)?

    private let log = Logger(subsystem: "com.klik.Klik", category: "tap")

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    private(set) var isRunning = false

    func start() -> Bool {
        guard !isRunning else { return true }
        guard AXIsProcessTrusted() else {
            log.error("Refusing to start: Accessibility permission not granted")
            return false
        }

        let ready = DispatchSemaphore(value: 0)
        var success = false

        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            success = self.installTap()
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            if success { CFRunLoopRun() }
        }
        thread.name = "com.klik.Klik.keytap"
        // The tap thread does nothing but forward keystrokes into the audio
        // graph, so it should never wait behind background work.
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread

        ready.wait()
        isRunning = success
        return success
    }

    /// Whether the tap is currently alive and delivering events.
    var isEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Re-arms the tap if the system has switched it off.
    ///
    /// macOS disables event taps across sleep/wake, screen lock and fast user
    /// switching. It is *supposed* to deliver `tapDisabledBy...` first, and the
    /// callback re-enables when it does -- but after a sleep that notification
    /// often never arrives, leaving a tap that is installed, silent, and
    /// reporting no error at all. Nothing recovers from that without checking.
    ///
    /// Returns true if the tap is alive when this returns.
    @discardableResult
    func ensureAlive() -> Bool {
        guard isRunning else { return false }
        guard let tap else { return false }
        if CGEvent.tapIsEnabled(tap: tap) { return true }

        log.notice("Tap was found disabled; re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) { return true }

        // Re-enabling a tap the system has fully torn down does nothing, so
        // build a new one.
        log.notice("Re-enable did not take; rebuilding the tap")
        stop()
        return start()
    }

    func stop() {
        guard isRunning else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        tap = nil
        source = nil
        runLoop = nil
        thread = nil
        isRunning = false
    }

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << Self.systemDefinedEventType)

        guard let tap = CGEvent.tapCreate(
            // HID level, not session level. Keys like Mission Control and
            // Spotlight are claimed by the window server before session taps
            // ever see them; this sits below that, close to the driver, so
            // those keys arrive too.
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("CGEvent.tapCreate failed")
            return false
        }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.notice("Event tap installed")
        return true
    }

    /// `NX_SYSDEFINED`. It has no `CGEventType` case, but the tap mask takes the
    /// raw value happily.
    private static let systemDefinedEventType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS` -- the media-key flavour of a
    /// system-defined event.
    private static let auxControlSubtype: Int16 = 8

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type.rawValue == Self.systemDefinedEventType {
            handleMediaKey(event)
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log.notice("Tap was disabled by the system; re-enabled")
            }

        case .keyDown, .keyUp:
            let vk = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            onKey?(vk, type == .keyDown, isRepeat)

        case .flagsChanged:
            let vk = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if let isDown = KeyCodes.modifierIsDown(virtualKey: vk, flags: event.flags) {
                onKey?(vk, isDown, false)
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Unless "Use F1, F2, etc. as standard function keys" is on, the function
    /// row does not send key events at all -- brightness and volume arrive as
    /// system-defined events instead, which is why they were silent.
    ///
    /// The key code and press state are packed into `data1` rather than exposed
    /// as event fields, so this goes through `NSEvent` to unpack them.
    private func handleMediaKey(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlSubtype else { return }

        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyFlags = data & 0x0000_FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1

        // Mission Control, Spotlight, Do Not Disturb and friends vary by keyboard
        // and macOS version, so anything unrecognised still gets a function-row
        // click rather than falling silent.
        let known = KeyCodes.mediaKeyToVirtualKey[keyCode]
        if known == nil && isDown {
            // Logged so unfamiliar function rows can be identified and mapped
            // properly rather than left on the generic sound:
            //   log show --last 5m --predicate 'subsystem == "com.klik.Klik"'
            log.notice("Unmapped media key code \(keyCode)")
        }
        onKey?(known ?? KeyCodes.genericFunctionKey, isDown, isRepeat)
    }
}
