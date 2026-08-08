import CoreAudio
import Foundation
import os

/// Finding out what someone is listening through.
///
/// There is no single "are headphones connected?" flag on macOS, because the
/// different ways of connecting announce themselves differently:
///
///   * AirPods and Bluetooth speakers appear as a whole new device.
///   * A USB headset or DAC also appears as a new device.
///   * Wired earphones in the 3.5mm jack do *not*. On some Macs a separate
///     "External Headphones" device appears, and on others the built-in device
///     stays put and merely switches its data source from speakers to headphones.
///
/// So this checks both: the transport of every output device, and the data
/// source of anything built-in.
enum OutputDevices {

    private static let log = Logger(subsystem: "com.klik.Klik", category: "devices")

    /// `'hdpn'`, the headphone data source on a built-in output.
    private static let headphoneDataSource: UInt32 = 0x6864_706E

    // MARK: - Queries

    /// The laptop's own speakers.
    static var builtInSpeakers: AudioDeviceID? {
        outputDevices().first { device in
            transportType(device) == kAudioDeviceTransportTypeBuiltIn
                && dataSource(device) != headphoneDataSource
        }
    }

    /// Name of an attached external listening device, or nil if the only thing
    /// available is the laptop's own speakers.
    static func externalOutput() -> String? {
        for device in outputDevices() {
            switch transportType(device) {
            case kAudioDeviceTransportTypeBluetooth,
                 kAudioDeviceTransportTypeBluetoothLE,
                 kAudioDeviceTransportTypeUSB,
                 kAudioDeviceTransportTypeAirPlay,
                 kAudioDeviceTransportTypeHDMI,
                 kAudioDeviceTransportTypeDisplayPort,
                 kAudioDeviceTransportTypeThunderbolt,
                 kAudioDeviceTransportTypeFireWire:
                return name(of: device)

            case kAudioDeviceTransportTypeBuiltIn:
                // Wired earphones in the headphone jack.
                if dataSource(device) == headphoneDataSource {
                    return name(of: device)
                }

            default:
                continue
            }
        }
        return nil
    }

    static func outputDevices() -> [AudioDeviceID] {
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

        return devices.filter(hasOutputStreams)
    }

    static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else {
            return "Audio device"
        }
        return value as String
    }

    static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    /// Which physical output a device is currently driving. On a built-in
    /// output this is how the headphone jack is detected.
    static func dataSource(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var source = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr else { return nil }
        return source
    }

    // MARK: - Monitoring

    private static var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Calls `onChange` whenever devices come or go, or the built-in output
    /// switches between speakers and the headphone jack.
    ///
    /// Plugging into the jack does not always change the device list, so the
    /// data source is watched as well.
    static func startMonitoring(onChange: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async(execute: onChange)
        }
        listenerBlock = block

        var deviceList = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceList, DispatchQueue.main, block)

        var defaultOutput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutput, DispatchQueue.main, block)

        var source = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        for device in outputDevices() where transportType(device) == kAudioDeviceTransportTypeBuiltIn {
            AudioObjectAddPropertyListenerBlock(device, &source, DispatchQueue.main, block)
        }

        log.notice("Watching audio devices; external now: \(externalOutput() ?? "none", privacy: .public)")
    }
}
