import AVFoundation
import Foundation

/// Command-line checks for the parts that do not need Accessibility permission:
/// pack discovery, decoding, and the cost of the per-keystroke path.
///
///   Klik --selftest    silent; reports packs, buffers and timings
///   Klik --demo        audible; types "klik" through the engine
enum SelfTest {

    /// CoreAudio identifiers are four packed characters, e.g. 'hdpn'.
    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .ascii) ?? "?"
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? "'\(text)'" : "\(value)"
    }

    static func run(audible: Bool, packPath: String?) -> Int32 {
        print("Klik self-test\n")

        var packs: [SoundPack] = []
        if let packPath {
            // Explicit directory, for checking a pack that is not installed yet.
            do {
                packs = [try SoundPackLoader.load(from: URL(fileURLWithPath: packPath))]
            } catch {
                print("FAIL  \(error.localizedDescription)")
                return 1
            }
        } else {
            packs = SoundPackLoader.discover()
        }

        guard !packs.isEmpty else {
            print("FAIL  no sound packs found in:")
            SoundPackLoader.searchPaths.forEach { print("        \($0.path)") }
            return 1
        }

        print("Packs found: \(packs.count)")
        for pack in packs {
            let downs = pack.keys.values.filter { $0.down != nil || $0.downFile != nil }.count
            let ups = pack.keys.values.filter { $0.up != nil }.count
            print(String(format: "  %-34s %3d keys  (%d down, %d up)",
                         (pack.name as NSString).utf8String!, pack.keys.count, downs, ups))
        }

        guard let pack = packs.first else { return 1 }
        print("\nLoading \"\(pack.name)\"")

        let engine = AudioEngine()
        engine.start(lowLatencyBuffer: true, builtInOutput: true)
        guard engine.isRunning else {
            print("FAIL  audio engine did not start")
            return 1
        }

        let loadStart = Date()
        do {
            try engine.load(pack: pack)
        } catch {
            print("FAIL  \(error.localizedDescription)")
            return 1
        }
        let loadMs = Date().timeIntervalSince(loadStart) * 1000

        print(String(format: "  decoded in %.0f ms", loadMs))
        print("  IO buffer: \(engine.ioBufferFrames) frames")
        print("  built-in speakers: \(engine.isUsingBuiltInOutput ? "pinned" : "NOT pinned, falling back to system output")")
        print(String(format: "  estimated output latency: %.2f ms", engine.estimatedLatencyMilliseconds))

        // A slice with the wrong offsets still decodes -- it just decodes to
        // silence. Check that the audio is actually there.
        print("\nsample check:")
        let probes: [(UInt16, String)] = [
            (0, "A"), (49, "Space"), (36, "Enter"), (51, "Backspace"),
            (56, "ShiftLeft"), (126, "ArrowUp"),
            // Keys the pack does not define, covered by the fallback chain.
            (55, "CmdLeft"), (54, "CmdRight"), (61, "OptRight"),
            (62, "CtrlRight"), (63, "Fn"),
            // Function row, reached through the media-key event path.
            (122, "F1"), (103, "F11"), (111, "F12"),
        ]
        var silent: [String] = []
        for (vk, name) in probes {
            guard let down = engine.inspect(virtualKey: vk, isDown: true) else {
                silent.append("\(name) (missing)")
                continue
            }
            let up = engine.inspect(virtualKey: vk, isDown: false)
            let seconds = Double(down.frames) / AudioEngine.canonicalFormat.sampleRate
            print(String(format: "  %-11s %5.0f ms  peak %.3f down / %.3f up",
                         (name as NSString).utf8String!, seconds * 1000,
                         down.peak, up?.peak ?? 0))
            if down.peak < 0.01 { silent.append(name) }
        }
        if !silent.isEmpty {
            print("FAIL  silent or missing: \(silent.joined(separator: ", "))")
            return 1
        }

        // Cost of the code that runs between a keypress and the sound being
        // handed to the audio graph. Silent -- this is a timing loop, not a demo.
        engine.volume = 0
        let keys: [UInt16] = [40, 37, 34, 4, 49, 0, 1, 2]
        var samples: [Double] = []
        samples.reserveCapacity(600)
        for i in 0..<600 {
            let key = keys[i % keys.count]
            let t0 = DispatchTime.now().uptimeNanoseconds
            engine.play(virtualKey: key, isDown: true)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
        }
        samples.sort()
        let mean = samples.reduce(0, +) / Double(samples.count)
        print(String(format: "\nper-keystroke dispatch cost over %d calls:", samples.count))
        print(String(format: "  mean %.1f us   median %.1f us   p99 %.1f us   max %.1f us",
                     mean, samples[samples.count / 2],
                     samples[Int(Double(samples.count) * 0.99)], samples.last!))

        print("\naudio devices:")
        for device in OutputDevices.outputDevices() {
            let transport = OutputDevices.transportType(device)
            let source = OutputDevices.dataSource(device)
            print(String(format: "  %-32s transport=%@ source=%@",
                         (OutputDevices.name(of: device) as NSString).utf8String!,
                         fourCC(transport),
                         source.map(fourCC) ?? "-"))
        }
        print("  external detected: \(OutputDevices.externalOutput() ?? "none, built-in speakers only")")

        print("\nmicrophones:")
        for device in Microphone.inputDevices() {
            print(String(format: "  %-32s %@",
                         (OutputDevices.name(of: device) as NSString).utf8String!,
                         Microphone.isRunning(device) ? "IN USE" : "idle"))
        }
        print("  in use: \(Microphone.activeInput() ?? "none")")

        // Does the graph actually render audio, and where is it going?
        print("\noutput check:")
        print("  device: \(engine.currentOutputDeviceName)")
        print("  pinned to built-in: \(engine.isUsingBuiltInOutput)")
        engine.volume = 0.8
        let rendered = engine.measureOutputPeak(seconds: 1.0) {
            for key in [0 as UInt16, 1, 2, 3, 49] {
                engine.play(virtualKey: key, isDown: true)
                Thread.sleep(forTimeInterval: 0.06)
            }
        }
        print(String(format: "  peak at mixer: %.4f", rendered))
        if rendered < 0.001 {
            print("  FAIL  the graph is producing silence")
            return 1
        }
        print("  graph is producing audio")

        if audible {
            print("\nPlaying \"klik\" ...")
            engine.volume = 0.8
            for key in [40 as UInt16, 37, 34, 40] {
                engine.play(virtualKey: key, isDown: true)
                Thread.sleep(forTimeInterval: 0.12)
                engine.play(virtualKey: key, isDown: false)
                Thread.sleep(forTimeInterval: 0.10)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        print("\nOK")
        return 0
    }
}
