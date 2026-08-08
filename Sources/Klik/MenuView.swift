import SwiftUI

struct MenuView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !state.isTrusted {
                permissionBanner
            }

            Divider()

            packPicker
            volumeSlider
            characterSlider

            Divider()

            Toggle("Sound on key release", isOn: $state.playOnKeyUp)
            Toggle("Ignore key repeats", isOn: $state.ignoreRepeats)
            Toggle("Silence during calls", isOn: $state.silenceWhenMicActive)
                .help("Goes quiet whenever any app is using a microphone, so your typing does not go into the call.")
            Toggle("Silence when headphones connected", isOn: $state.silenceWithExternalAudio)
                .help("Drops Klik to 0% whenever AirPods, Bluetooth speakers, wired earphones or a USB headset are connected.")
            Toggle("Always use built-in speakers", isOn: $state.builtInOutput)
                .help("Keeps typing sounds in the room, out of your headphones, the way a real keyboard behaves.")
            Toggle("Low-latency audio buffer", isOn: $state.lowLatencyBuffer)
                .help("Shrinks the output device's render quantum. Takes effect immediately, and affects other apps sharing the output device.")
            Toggle("Launch at login", isOn: $state.launchAtLogin)

            welcomeRow

            Divider()
            keyMonitor

            if let status = state.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 290)
        .onAppear {
            state.refreshLatency()
            state.setMonitoring(true)
        }
        .onDisappear { state.setMonitoring(false) }
    }

    /// Greeting typed at launch. The text field is here rather than hidden in a
    /// settings file so it is obvious the word is yours to change.
    private var welcomeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Type a greeting at launch", isOn: $state.welcomeEnabled)

            if state.welcomeEnabled {
                HStack(spacing: 6) {
                    TextField("word", text: $state.welcomeText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button {
                        state.playWelcome()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .controlSize(.small)
                    .help("Hear it now")
                }
                .padding(.leading, 2)
            }
        }
    }

    /// Live readout of what the listener is receiving. This is the first place to
    /// look when a key seems dead: if nothing appears here the key never reached
    /// Klik, and if it says "no sound" the pack has nothing for it.
    private var keyMonitor: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Last key").font(.caption).foregroundStyle(.secondary)
            Text(state.lastKey ?? "press any key…")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(state.lastKey == nil ? .secondary : .primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Toggle("", isOn: $state.isEnabled)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text("Klik")
                    .font(.headline)
                Text(state.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.hotKeyRegistered {
                Text(GlobalHotKey.muteDescription)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Mute or unmute Klik from anywhere")
            }
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Klik needs Accessibility access to see keystrokes.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings…") { state.requestPermission() }
                .controlSize(.small)
            Text("Enable Klik under Privacy & Security → Accessibility. It starts working the moment you do, with no relaunch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var packPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sound pack").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Picker("", selection: $state.selectedPackID) {
                    ForEach(state.packs) { pack in
                        Text(pack.name).tag(pack.id)
                    }
                }
                .labelsHidden()
                .disabled(state.packs.isEmpty)

                Button {
                    state.playDemo()
                } label: {
                    Image(systemName: "play.fill")
                }
                .controlSize(.small)
                .help("Hear this pack")
            }
            Text("Picking a pack plays it straight away.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var volumeSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Volume").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(state.effectiveVolume * 100))%")
                    .font(.caption)
                    .foregroundStyle(state.isSilencedByExternalAudio ? .orange : .secondary)
            }
            Slider(value: $state.volume, in: 0...1)
                .disabled(state.isSilencedByExternalAudio)

            if state.isSilencedByMicrophone {
                Label("Silenced, \(state.activeMicrophone ?? "microphone") in use",
                      systemImage: "mic.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.isSilencedByExternalAudio {
                Label("Silenced, \(state.externalAudio ?? "headphones") connected",
                      systemImage: "headphones")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var characterSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Variation").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(state.pitchVariance < 0.005
                     ? "off"
                     : "±\(Int(state.pitchVariance * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $state.pitchVariance, in: 0...0.12)
                .help("Per-keystroke pitch drift. Stops a small sample set from sounding like a loop.")
        }
    }

    private var footer: some View {
        HStack {
            Button("Pack Folder…") { state.revealUserPacksFolder() }
                .controlSize(.small)
            Button("Reload") { state.reloadPacks() }
                .controlSize(.small)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}
