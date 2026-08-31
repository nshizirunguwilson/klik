import AVFoundation
import CoreAudio
import Foundation

/// Checks that Klik keeps making sound while audio devices come and go.
///
///   Klik --devicetest
///
/// This is the one failure the ordinary self-test cannot see. Everything the
/// engine reports about itself stays healthy across a device change: the engine
/// says it is running, every voice says it is connected and playing. The only
/// way to catch it is to listen to what the mixer actually renders, before and
/// after each change.
///
/// It switches the system's default output device while it runs, and puts the
/// original back on the way out.
enum DeviceTest {

    static func run(packPath: String?) -> Int32 {
        print("Klik audio device test\n")
        print("This switches your default output device several times.")
        print("It is put back at the end.\n")

        let outputs = OutputDevices.outputDevices()
        for device in outputs {
            print("  \(OutputDevices.name(of: device))")
        }
        guard outputs.count >= 2 else {
            print("\nSKIP  needs a second output device connected (AirPods, earphones, a USB headset).")
            return 0
        }
        guard let original = defaultOutput() else {
            print("\nFAIL  cannot read the default output device.")
            return 1
        }
        // Put the machine back the way it was even if a check bails out early.
        defer { setDefaultOutput(original) }

        let discovered: [SoundPack]
        if let packPath {
            discovered = (try? SoundPackLoader.load(from: URL(fileURLWithPath: packPath))).map { [$0] } ?? []
        } else {
            discovered = SoundPackLoader.discover()
        }
        guard let pack = discovered.first else {
            print("\nFAIL  no sound packs found.")
            return 1
        }
        let engine = AudioEngine()
        engine.start(lowLatencyBuffer: true, builtInOutput: true)
        do { try engine.load(pack: pack) } catch {
            print("\nFAIL  \(error.localizedDescription)")
            return 1
        }
        engine.volume = 0.5

        let speakers = OutputDevices.builtInSpeakers ?? original
        let other = outputs.first { $0 != speakers } ?? original

        var failures: [String] = []

        func check(_ label: String) {
            let peak = engine.measureOutputPeak(seconds: 0.6) {
                for key in [0 as UInt16, 1, 2, 49] {
                    engine.play(virtualKey: key, isDown: true)
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            let ok = peak > 0.001
            print(String(format: "  %-40s peak %.4f  %@",
                         (label as NSString).utf8String!, peak, ok ? "sound" : "SILENT"))
            if !ok { failures.append(label) }
        }

        print("\nplaying through each change:")
        check("at launch")

        setDefaultOutput(other)
        settle()
        check("after \(OutputDevices.name(of: other)) became default")

        // The pin is what the "always use built-in speakers" switch does, and it
        // is the step that used to kill the graph.
        engine.setBuiltInOutput(false)
        settle()
        check("following system output")

        engine.setBuiltInOutput(true)
        settle()
        check("pinned back to built-in speakers")

        setDefaultOutput(original)
        settle()
        check("after the device went away again")

        // Connecting and disconnecting in a hurry is the realistic case: a
        // Bluetooth device announces itself several times as it settles.
        for round in 1...3 {
            setDefaultOutput(round.isMultiple(of: 2) ? speakers : other)
            settle(0.5)
            check("connect and disconnect, round \(round)")
        }

        engine.shutdown()

        if failures.isEmpty {
            print("\nOK  sound survived every device change")
            return 0
        }
        print("\nFAIL  went silent at: \(failures.joined(separator: "; "))")
        return 1
    }

    /// Device changes are not instant, and a Bluetooth device is slower than
    /// most. Give the system time to finish before asking for sound.
    private static func settle(_ seconds: TimeInterval = 1.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func setDefaultOutput(_ device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = device
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }
}
