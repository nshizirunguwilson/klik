import CoreAudio
import Foundation
import os

/// Whether anything on the Mac is currently listening through a microphone.
///
/// This is the case Klik most needs to stay out of. On a call with no headphones,
/// every click goes into the mic and out to everyone else, the exact complaint
/// people have about real mechanical keyboards. Headphone detection does not
/// cover it, because a laptop-mic call involves no headphones at all.
///
/// CoreAudio exposes this directly: a device reports whether it is "running
/// somewhere", meaning some process has it open and streaming.
enum Microphone {

    private static let log = Logger(subsystem: "com.klik.Klik", category: "mic")

    static func isInUse() -> Bool {
        inputDevices().contains(where: isRunning)
    }

    /// Name of a microphone currently in use, for showing in the menu.
    static func activeInput() -> String? {
        inputDevices().first(where: isRunning).map(OutputDevices.name(of:))
    }

    static func inputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }

        return devices.filter(hasInputStreams)
    }

    static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    /// True when some process currently has this input open and streaming.
    static func isRunning(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private static var listener: AudioObjectPropertyListenerBlock?

    /// Watches every input for someone starting or stopping a recording.
    ///
    /// The device list is watched too, so a microphone that appears later
    /// (a USB headset, a webcam) is picked up rather than missed.
    static func startMonitoring(onChange: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async(execute: onChange)
        }
        listener = block

        var running = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for device in inputDevices() {
            AudioObjectAddPropertyListenerBlock(device, &running, DispatchQueue.main, block)
        }

        var deviceList = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceList, DispatchQueue.main) { _, _ in
                // A new input appeared; start watching it as well.
                for device in inputDevices() {
                    AudioObjectAddPropertyListenerBlock(device, &running, DispatchQueue.main, block)
                }
                DispatchQueue.main.async(execute: onChange)
            }

        log.notice("Watching microphones; in use now: \(isInUse())")
    }
}
