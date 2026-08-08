import Foundation
import os

/// A slice of the pack's sprite audio, in seconds.
struct Slice {
    var start: TimeInterval
    var end: TimeInterval
    var duration: TimeInterval { max(0, end - start) }
}

/// What to play for one physical key.
struct KeySound {
    var down: Slice?
    var up: Slice?
    /// Set instead of the slices for multi-file packs, which give each key its
    /// own audio file rather than an offset into a shared sprite.
    var downFile: URL?
}

/// A parsed pack: metadata plus a key map, but no decoded audio yet.
struct SoundPack: Identifiable, Hashable {
    var id: String
    var name: String
    var directory: URL
    /// The shared sprite. Nil for multi-file packs.
    var audioURL: URL?
    var keys: [UInt16: KeySound]
    var recommendedVolume: Float

    static func == (a: SoundPack, b: SoundPack) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum SoundPackError: LocalizedError {
    case unreadable(URL)
    case noDefinitions
    case missingAudio(String)
    case undecodableAudio(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read \(url.lastPathComponent)."
        case .noDefinitions:
            return "The pack has no key definitions."
        case .missingAudio(let name):
            return "The pack's audio file \(name) is missing."
        case .undecodableAudio(let name):
            return "\(name) is an Ogg file, which macOS cannot decode. "
                 + "Run tools/prepare_pack.sh on the pack to convert it to WAV."
        }
    }
}

enum SoundPackLoader {

    private static let log = Logger(subsystem: "com.klik.Klik", category: "packs")

    /// Every directory Klik looks in for packs. Bundled packs first, then the
    /// user's own, so a user pack with the same id wins.
    static var searchPaths: [URL] {
        var paths: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("SoundPacks") {
            paths.append(bundled)
        }
        paths.append(userPacksDirectory)
        return paths
    }

    static var userPacksDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Klik/SoundPacks", isDirectory: true)
    }

    static func discover() -> [SoundPack] {
        var byID: [String: SoundPack] = [:]
        var order: [String] = []

        for root in searchPaths {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                do {
                    let pack = try load(from: entry)
                    if byID[pack.id] == nil { order.append(pack.id) }
                    byID[pack.id] = pack
                } catch {
                    log.error("Skipping pack at \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return order.compactMap { byID[$0] }
    }

    static func load(from directory: URL) throws -> SoundPack {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SoundPackError.unreadable(configURL)
        }

        let id = (root["id"] as? String) ?? directory.lastPathComponent
        let name = (root["name"] as? String) ?? directory.lastPathComponent
        let volume = (root["options"] as? [String: Any])?["recommended_volume"] as? Double

        let keys: [UInt16: KeySound]
        let audioName: String?

        if let definitions = root["definitions"] as? [String: Any] {
            // v2 (MechvibesDX): W3C key codes with explicit down/up timings.
            keys = parseV2(definitions)
            audioName = root["audio_file"] as? String
        } else if let defines = root["defines"] as? [String: Any] {
            // v1 (original Mechvibes): numeric scancodes.
            let multi = (root["key_define_type"] as? String) == "multi"
            keys = parseV1(defines, multiFile: multi, directory: directory)
            audioName = multi ? nil : (root["sound"] as? String)
        } else {
            throw SoundPackError.noDefinitions
        }

        guard !keys.isEmpty else { throw SoundPackError.noDefinitions }

        var audioURL: URL?
        if let audioName {
            audioURL = try resolveAudio(named: audioName, in: directory)
        }

        return SoundPack(
            id: id,
            name: name,
            directory: directory,
            audioURL: audioURL,
            keys: keys,
            recommendedVolume: volume.map { Float($0) } ?? 1.0
        )
    }

    /// Prefers a WAV sibling, because `AVAudioFile` cannot decode the Ogg Vorbis
    /// that most packs ship. `tools/prepare_pack.sh` produces that sibling.
    private static func resolveAudio(named name: String, in directory: URL) throws -> URL {
        let declared = directory.appendingPathComponent(name)
        let wav = directory.appendingPathComponent((name as NSString).deletingPathExtension + ".wav")

        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        if FileManager.default.fileExists(atPath: declared.path) {
            if (name as NSString).pathExtension.lowercased() == "ogg" {
                throw SoundPackError.undecodableAudio(name)
            }
            return declared
        }
        throw SoundPackError.missingAudio(name)
    }

    private static func parseV2(_ definitions: [String: Any]) -> [UInt16: KeySound] {
        // Invert the key map once so lookup is by pack identifier.
        var byCode: [String: UInt16] = [:]
        for (vk, code) in KeyCodes.toW3C { byCode[code] = vk }

        var result: [UInt16: KeySound] = [:]
        for (code, value) in definitions {
            guard let vk = byCode[code],
                  let entry = value as? [String: Any],
                  let timing = entry["timing"] as? [[Double]] else { continue }

            var sound = KeySound()
            if let d = timing.first, d.count >= 2 {
                sound.down = Slice(start: d[0] / 1000, end: d[1] / 1000)
            }
            if timing.count > 1, timing[1].count >= 2 {
                sound.up = Slice(start: timing[1][0] / 1000, end: timing[1][1] / 1000)
            }
            if sound.down != nil || sound.up != nil { result[vk] = sound }
        }
        return result
    }

    private static func parseV1(_ defines: [String: Any], multiFile: Bool, directory: URL) -> [UInt16: KeySound] {
        var result: [UInt16: KeySound] = [:]

        for (vk, candidates) in KeyCodes.toLegacy {
            // Extended keys have more than one encoding in circulation; take
            // whichever one this pack actually defines.
            guard let value = candidates.lazy
                    .compactMap({ defines["\($0)"] })
                    .first(where: { !($0 is NSNull) }) else { continue }

            if multiFile {
                guard let filename = value as? String,
                      let url = try? resolveAudio(named: filename, in: directory) else { continue }
                result[vk] = KeySound(downFile: url)
            } else {
                // [offset_ms, duration_ms] -- note the second element is a
                // duration here, unlike v2 where it is an end timestamp.
                guard let pair = value as? [Double], pair.count >= 2 else { continue }
                let start = pair[0] / 1000
                result[vk] = KeySound(down: Slice(start: start, end: start + pair[1] / 1000))
            }
        }
        return result
    }
}
