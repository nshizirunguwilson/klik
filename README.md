# Klik

A macOS menu bar app that gives any keyboard the sound of a mechanical one.

Klik plays real mechanical switch recordings as you type, on any keyboard, including
the built-in MacBook one. It runs offline, logs nothing, and sends nothing anywhere.

## Build and run

```sh
./build.sh install
```

That compiles a release build, assembles the app, signs it, copies it to
`/Applications`, and launches it. Install rather than just run: Accessibility
permission and the login item both remember *where* the app is, and `build/` is
deleted on every rebuild.

`./build.sh` alone builds without launching, `./build.sh run` launches from `build/`,
and `./build.sh debug` builds unoptimised.

**Klik needs Accessibility permission** to see keystrokes, and there is no way around
this for a global key listener. On first launch the menu shows a banner with a button
that opens the right settings pane. Enable Klik under *Privacy & Security →
Accessibility* and it starts working immediately, no relaunch.

### Signing

`build.sh` signs with the first real certificate it finds (a Developer ID, an Apple
Development certificate, or a self-signed `Klik Local Signing` one), falling back to
ad-hoc only if there is nothing available.

This matters more than it sounds. macOS ties the Accessibility permission to the app's
signature, so an ad-hoc signature (which changes on every single build) means
re-granting permission on every single build. Any real certificate keeps the grant.

If you have no certificate, make one once:

```sh
tools/create_signing_identity.sh
```

Override the choice with `KLIK_SIGN_IDENTITY="Some Identity" ./build.sh`.

## Checking it without granting permission

```sh
./build/Klik.app/Contents/MacOS/Klik --demo      # audible: types "klik"
./build/Klik.app/Contents/MacOS/Klik --selftest  # silent: packs, buffers, timings
```

`--selftest` reports what loaded, the audio buffers' peak levels, the render quantum
the output device granted, and the cost of the per-keystroke path.

## The menu

| Control | What it does |
|---|---|
| Master toggle | Silences Klik without quitting it. Also bound to **⌃⌥⌘M** globally. |
| Status line | `Listening` plus the output latency; or `Waiting for permission`. |
| Sound pack | Which recording to use. ABS is brighter, PBT is deeper. |
| Volume | Output level, independent of system volume. |
| Variation | Per-keystroke pitch and gain drift. At 0 the repetition becomes audible. |
| Sound on key release | Play the upstroke sample too. Faithful to a real switch. |
| Ignore key repeats | Holding a key does not re-actuate a real switch, so by default it stays quiet. |
| Silence when headphones connected | Forces Klik to 0% whenever AirPods, Bluetooth speakers, wired earphones or a USB headset are connected. Your slider value is kept and restored on disconnect. |
| Always use built-in speakers | Pins playback to the laptop speakers, so typing stays in the room even when everything else is going to headphones. |
| Low-latency audio buffer | 128-frame render quantum instead of 512. Applies immediately. Device-wide. |
| Launch at login | Registered through `SMAppService`. Re-toggle it if you move the app. |
| Last key | Live readout of what the listener received, and whether it had a sound. |
| Pack Folder… / Reload | Open the user pack directory; rescan without restarting. |

**Last key** is the diagnostic. If a key seems dead: nothing appearing there means the
key never reached Klik at all, whereas `no sound` means it arrived but the pack has
nothing for it.

## Sound packs

Eight packs ship with the app, from the MechvibesDX collection:

| Pack | Character |
|---|---|
| CherryMX Blue (ABS) | Sharp click, the loudest and most recognisable |
| CherryMX Black (ABS / PBT) | Linear, firm, no click |
| CherryMX Brown (PBT) | Tactile bump, muted middle ground |
| CherryMX Red (ABS) | Light and quick, higher pitched |
| Topre Purple Hybrid (PBT) | Soft rounded "thock", nothing like the Cherrys |
| EG Oreo | Deep and creamy, low end |
| EG Crystal Purple | Bright, glassy, high pitched |

Drop more into:

```
~/Library/Application Support/Klik/SoundPacks/<pack-name>/
```

then hit **Reload** in the menu. **Pack Folder…** opens that directory.

Both Mechvibes pack generations are supported: v1 (`defines` with numeric scancodes,
single-sprite or one-file-per-key) and v2 / MechvibesDX (`definitions` with W3C key
codes and separate press/release timings).

Packs have gaps. They are recordings of real keyboards, usually PC ones, which have
no Command key at all, and whose authors typically captured only one of each modifier
pair. Klik fills those gaps by borrowing the sample from the most physically similar
key it does have (Command from Option, right Control from left Control), so no key on
the keyboard is ever silent.

Most packs ship Ogg Vorbis, which macOS cannot decode. Convert before use:

```sh
tools/prepare_pack.sh ~/Library/Application\ Support/Klik/SoundPacks/my-pack
```

This writes a `.wav` next to the original; Klik prefers it automatically.

## Why it's built this way

The interesting constraint is latency. Past roughly 20 ms between keypress and sound,
the brain stops accepting it as the keyboard's own noise. Three things follow:

- **Nothing decodes while typing.** The whole sprite is decoded at load and sliced
  into a ready buffer per key, per direction. A keystroke costs one `scheduleBuffer`.
- **The graph is built once.** 24 voices of `player → varispeed → mixer`, wired at
  startup and never rewired. Every player is started immediately and left running, so
  a keystroke involves no state transition. An idle player just renders silence.
  The one exception is an output device change, which macOS handles by stopping the
  engine; Klik catches that and restarts.
- **Key events come from a CoreGraphics event tap**, not the app framework. The tap is
  `.listenOnly`, so it sits outside the input path and a slow callback cannot stall
  typing system-wide. The callback reads a key code and hands it straight to the audio
  graph on the same thread, with no dispatch hop.

The tap is also watched, not assumed. macOS disables event taps across sleep, screen
lock and fast user switching. It is meant to deliver a `tapDisabledBy...` event first,
and the callback re-arms when it does. But after a sleep that notification frequently
never arrives, leaving a tap that is installed, silent, and reporting no error. So a
timer checks `CGEventTapIsEnabled` every five seconds, plus immediately on wake, and
rebuilds the tap outright if re-enabling does not take.

The tap listens on four event types, not one. Ordinary keys arrive as `keyDown`/`keyUp`,
modifiers as `flagsChanged` (with press-vs-release read out of the device-dependent flag
bits, since the public masks cannot tell left from right), and the function row as
`NX_SYSDEFINED`, because unless "Use F1, F2, etc. as standard function keys" is on,
brightness and volume keys send no key event at all.

On top of that, Klik asks the output device for a 128-frame render quantum instead of
the usual 512, which is worth about 8 ms on its own. That is a device-wide setting
shared with other apps, so it can be turned off in the menu.

Per-keystroke pitch and gain randomisation is what stops ~96 samples from sounding
like a loop. The **Variation** slider controls it; at zero, playback is flat.

Measured on the development machine: 2.79 ms of output latency, and a median 1.8 µs
(p99 85 µs) spent between the tap callback and the buffer being scheduled.

## Layout

```
Sources/Klik/
  KlikApp.swift      MenuBarExtra scene, CLI entry point
  AppState.swift     settings, permission watch, wiring
  MenuView.swift     the menu UI
  AudioEngine.swift  decode, slice, node pool, playback
  KeyTap.swift       CGEvent tap on its own run loop thread
  KeyCodes.swift     macOS virtual key codes → pack key identifiers
  SoundPack.swift    v1 and v2 config parsing
  SelfTest.swift     --selftest / --demo
SoundPacks/          bundled packs, copied into the app at build time
tools/prepare_pack.sh
```
