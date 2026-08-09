# Klik: Full Project Documentation

A complete reference for the project: what it is, how every part works, why each
decision was made, and how to run, extend and troubleshoot it.

---

## Table of contents

1. [What Klik is](#1-what-klik-is)
2. [The core problem: latency](#2-the-core-problem-latency)
3. [How a keystroke becomes a sound](#3-how-a-keystroke-becomes-a-sound)
4. [Project layout](#4-project-layout)
5. [The source files, one by one](#5-the-source-files-one-by-one)
6. [Sound packs](#6-sound-packs)
7. [Permissions](#7-permissions)
8. [Code signing](#8-code-signing)
9. [Building and installing](#9-building-and-installing)
10. [Every menu control](#10-every-menu-control)
11. [The self test](#11-the-self-test)
12. [Problems hit during development](#12-problems-hit-during-development)
13. [Measured performance](#13-measured-performance)
14. [Troubleshooting](#14-troubleshooting)
15. [Limitations and future work](#15-limitations-and-future-work)

---

## 1. What Klik is

Klik is a macOS menu bar application that plays recorded mechanical keyboard
switch sounds as you type. It works with any keyboard, including the built in
MacBook one, and adds no perceptible delay between the keypress and the sound.

The idea came from a simple annoyance: mechanical keyboards sound good but are
loud, expensive and impractical to carry. Klik gives you the audio feedback
without the hardware.

**Key properties**

* Runs entirely offline. Nothing is logged, stored, or transmitted.
* Lives in the menu bar with no Dock icon and no window.
* Reads swappable sound packs compatible with the Mechvibes community format,
  so it inherits a large existing library of switch recordings.
* Silences itself automatically during calls and when headphones are connected.

**Technology used**

| Area | Choice |
| --- | --- |
| Language | Swift 5.9 or later (built with Swift 6.3) |
| Interface | SwiftUI, using `MenuBarExtra` |
| Audio | AVFoundation, specifically `AVAudioEngine` |
| Low level audio | CoreAudio, for device selection and buffer sizing |
| Key capture | CoreGraphics `CGEvent` tap |
| Permission check | ApplicationServices, `AXIsProcessTrusted` |
| Global shortcut | Carbon `RegisterEventHotKey` |
| Launch at login | ServiceManagement, `SMAppService` |
| Build | Swift Package Manager plus a shell script |
| Sample preparation | ffmpeg |
| Deployment target | macOS 14 Sonoma |

---

## 2. The core problem: latency

The interesting engineering problem in Klik is not the interface. It is delay.

Above roughly 20 milliseconds between a keypress and its sound, your brain stops
accepting the sound as belonging to the key you pressed. It starts to feel like a
separate noise happening nearby. Everything in the architecture serves the goal of
staying comfortably under that threshold.

There are four places delay can accumulate, and each one is addressed directly.

### 2.1 Decoding audio

**The risk:** decoding a compressed audio file takes milliseconds to tens of
milliseconds. Doing that per keystroke would blow the entire budget on its own.

**The solution:** every sample is decoded into raw PCM at load time and sliced
into a ready made buffer for each key, in each direction. While you are typing,
nothing touches the disk and nothing runs a decoder. Loading all 96 keys of a pack
takes about 10 milliseconds and happens once.

### 2.2 Building the audio graph

**The risk:** attaching, connecting or reconfiguring audio nodes causes the audio
engine to reconfigure itself, which stalls.

**The solution:** the graph is built once at startup and never rewired. It is 24
independent voices, each one a player node feeding a varispeed node feeding the
main mixer. Every player is started immediately and left running forever. An idle
player renders silence, which costs nothing, so playing a key requires no state
change at all: just one call to schedule a buffer.

The single exception is when the output device changes, for example when you
connect headphones. macOS stops the engine in that case, so Klik catches the
notification and restarts.

### 2.3 Receiving the keystroke

**The risk:** going through the normal application framework means waiting for
the event to be routed and dispatched.

**The solution:** keys are read from a CoreGraphics event tap, which sits far
below the application layer, and the callback runs on a dedicated high priority
thread. The callback reads the key code and hands it straight to the audio graph
on that same thread, with no hop to another queue.

### 2.4 The hardware buffer

**The risk:** macOS processes audio in chunks. The default chunk is 512 frames,
which is about 11 milliseconds of latency before anything else is counted.

**The solution:** Klik asks the output device for 128 frames instead, which is
about 3 milliseconds. This is a device wide setting shared with other
applications, so it is exposed as a switch rather than forced, and the original
value is restored when Klik quits.

### 2.5 Avoiding the loop effect

Latency is not the only thing that breaks the illusion. A pack has around 96
recordings. Played back identically every time, the ear detects the repetition
within seconds and the effect collapses into an obvious loop.

Klik randomises pitch and gain slightly on every keystroke. Pitch comes from the
varispeed node, whose rate is set just before the buffer is scheduled. Gain is set
on the player node. The amount is controlled by the Variation slider, and setting
it to zero disables the effect entirely.

---

## 3. How a keystroke becomes a sound

```
   You press a key
          |
          v
  +-------------------+
  |  macOS HID layer  |
  +-------------------+
          |
          v
  +----------------------------------+
  |  KeyTap                          |   dedicated thread, high priority
  |  CGEvent tap at HID level        |
  |  listen only, cannot block input |
  +----------------------------------+
          |
          |  virtual key code, is it down, is it a repeat
          v
  +----------------------------------+
  |  AppState.wireTap closure        |   reads three flags behind a lock
  |  muted? key up wanted? repeat?   |
  +----------------------------------+
          |
          v
  +----------------------------------+
  |  AudioEngine.play                |
  |  look up buffer for this key     |
  |  pick next voice, round robin    |
  |  set varispeed rate, set volume  |
  |  scheduleBuffer                  |
  +----------------------------------+
          |
          v
  +----------------------------------+
  |  Main mixer, then output device  |
  |  pinned to built in speakers     |
  +----------------------------------+
          |
          v
       You hear it
```

The whole path from tap callback to scheduled buffer takes a median of about 2
microseconds. The remaining delay is the audio hardware itself, measured at 2.79
milliseconds.

---

## 4. Project layout

```
klik/
  description.txt                     the original project brief
  README.md                           short usage guide
  DOCUMENTATION.md                    this file
  Package.swift                       Swift Package Manager manifest
  build.sh                            build, bundle, sign, install

  Sources/Klik/
    KlikApp.swift                     entry point and MenuBarExtra scene
    AppState.swift                    settings, wiring, all the policy
    MenuView.swift                    the menu bar interface
    AudioEngine.swift                 decoding, slicing, playback
    KeyTap.swift                      the global key listener
    KeyCodes.swift                    key code translation tables
    SoundPack.swift                   pack discovery and config parsing
    OutputDevices.swift               speaker and headphone detection
    Microphone.swift                  microphone in use detection
    GlobalHotKey.swift                system wide mute shortcut
    LoginItem.swift                   launch at login
    Accessibility.swift               permission check and prompt
    SelfTest.swift                    command line diagnostics

  Resources/
    Info.plist                        bundle metadata
    AppIcon.icns                      generated icon

  SoundPacks/                         eight bundled packs
  tools/
    prepare_pack.sh                   Ogg to WAV conversion
    make_icon.swift                   draws the app icon
    create_signing_identity.sh        makes a self signed certificate
    export_signing_identity.sh        backs a certificate up
    import_signing_identity.sh        restores a certificate
```

---

## 5. The source files, one by one

### 5.1 KlikApp.swift

The entry point. It is deliberately tiny.

Before the interface starts, it checks the command line arguments. If it sees
`--selftest` or `--demo` it runs the diagnostics and exits, which is how the app
can be tested without any interface or permission. Otherwise it starts the SwiftUI
application.

The scene is a `MenuBarExtra` using the window style, which allows sliders and
text fields in the menu. The menu bar glyph is an SF Symbol that switches between
a filled and an outlined keyboard depending on whether Klik is muted, so the state
is visible at a glance without opening anything.

### 5.2 AppState.swift

The largest file, and the one holding all the policy. It owns the audio engine,
the key listener, the mute shortcut, and every setting.

**Settings.** Each user setting is a published property with a `didSet` that saves
to `UserDefaults` and applies the change immediately. Settings are restored at
startup before anything else happens.

**The hot path.** The closure connecting the key listener to the audio engine is
the most performance sensitive code in the project. It reads three flags from a
lock protected structure, decides whether the key should make a sound, and calls
the audio engine. It never touches published properties, because those are main
actor isolated and reaching them from the listener thread would be both a race and
a delay.

The one exception is the key monitor. When the menu is open, the closure also
sends a description of the key to the interface. This costs a hop to the main
thread, so it only happens while the menu is actually visible.

**Effective volume.** The volume the engine receives is not always the volume on
the slider. Two rules can force it to zero: a microphone being in use, and
external audio being connected. The slider value itself is never overwritten, so
when the condition clears your chosen level returns exactly as it was.

**Silence reason.** A single computed property answers the question "why is Klik
quiet?" by checking every possibility in order: no permission, dead listener,
muted, microphone active, headphones connected, volume at zero. The menu shows the
result. This exists because silence has six possible causes and, without this, all
six look identical.

**The watchdog.** A timer runs every five seconds and asks the key listener
whether it is still alive, plus re-checks the audio devices. There is also an
immediate check when the Mac wakes. Section 12 explains why this is necessary.

### 5.3 MenuView.swift

The interface. A single vertical stack, roughly 290 points wide, containing the
master toggle, status line, pack picker, sliders, switches, the key monitor and
the footer buttons.

It turns key monitoring on when it appears and off when it disappears, so that the
cost is only paid while someone is looking.

### 5.4 AudioEngine.swift

The audio side, and the most detailed file in the project.

**Canonical format.** Everything is converted at load time to 44100 Hz, two
channel, 32 bit float. Fixing the format means the graph can be built once with
one format regardless of what a given pack contains. Packs recorded at other rates
are converted with `AVAudioConverter` during loading.

**Loading a pack.** The pack's single sprite file is decoded fully into memory,
then each key's slice is copied into its own buffer. For multi file packs each
file is decoded separately.

**Fades.** Slice boundaries land wherever the pack author put them, often in the
middle of a waveform. Cutting there produces an audible click on top of the click
you wanted. Every buffer gets a 1 millisecond fade in and a 4 millisecond fade
out to prevent that.

**Gap filling.** Packs are recordings of real keyboards, usually PC keyboards,
which have no Command key at all. Authors also routinely record only one of each
modifier pair. After loading, any key with no sound borrows one from the most
physically similar key that does have one, so nothing on the keyboard is silent.
A generic fallback catches anything with no sensible neighbour.

**Playing.** Round robin across 24 voices. Each play sets the varispeed rate, sets
the player volume, and schedules the buffer with the interrupt option so a reused
voice cuts cleanly rather than queueing.

**Device control.** The engine can pin its output to the built in speakers by
setting the device ID on the output audio unit. This must happen while the engine
is stopped, so changing it restarts the graph. The engine also remembers each
device's original buffer size and restores it on quit.

**Diagnostics.** Two methods exist purely for the self test: one reports the frame
count and peak amplitude of a loaded key, and one installs a tap on the mixer to
measure what the graph is really rendering. The second one distinguishes two
failures that both sound like silence: producing nothing, versus producing
something and sending it somewhere you are not listening.

### 5.5 KeyTap.swift

The global key listener.

**Where it sits.** The tap is created at the HID level rather than the session
level. Keys such as Mission Control and Spotlight are claimed by the window server
before session level taps see them, so a session tap misses them entirely. The HID
level sits below that, close to the driver.

**Listen only.** The tap is created in listen only mode. This matters: a filtering
tap sits in the input path, so a slow callback stalls typing across the entire
system. A listening tap cannot do that.

**Its own thread.** The tap runs on a dedicated thread with its own run loop, at
user interactive quality of service, so it never waits behind background work.

**Four event types.** Ordinary keys arrive as key down and key up. Modifiers
arrive as flags changed, where press versus release has to be read out of the flag
bits, using the device dependent bits because the public masks cannot tell left
from right. The function row arrives as `NX_SYSDEFINED` media events, because
unless standard function keys are enabled, that row sends no key events at all.

**Staying alive.** `ensureAlive` checks whether the tap is still enabled,
re-enables it if not, and rebuilds it from scratch if re-enabling does not work.

### 5.6 KeyCodes.swift

Pure data and translation, no behaviour.

* `toW3C` maps macOS virtual key codes to W3C `KeyboardEvent.code` strings, which
  is what modern packs are keyed by.
* `toLegacy` maps them to the numeric scancodes that older packs use. Extended
  keys list several candidate codes, because different pack authors encoded the
  prefix differently and there is no single correct answer.
* `fallbacks` says where to borrow a sound from when a pack lacks a key.
* `mediaKeyToVirtualKey` maps media key codes back to the function key that
  physically occupies that position.
* `modifierIsDown` reads press versus release out of the flag bits.
* `displayName` produces readable names for the key monitor.
* `virtualKeys(for:)` turns a word into the keys you would press to type it, which
  is what powers the launch greeting.

### 5.7 SoundPack.swift

Discovery and parsing. It searches the bundled pack folder first, then the user's
folder, so a user pack with the same identifier wins.

It supports both pack generations. Version 2 uses W3C key names and carries
separate press and release timings, given as start and end timestamps. Version 1
uses numeric scancodes and a single timing per key, given as an offset and a
duration. Note the difference: the second number means different things in the two
formats, which is an easy mistake to make.

It also resolves the audio file, preferring a WAV sibling if one exists, because
macOS cannot decode Ogg Vorbis and most packs ship exactly that.

### 5.8 OutputDevices.swift

Answers "what is this person listening through?"

There is no single flag for this on macOS, because each kind of connection
announces itself differently. AirPods and Bluetooth speakers appear as new
devices. USB headsets appear as new devices. Wired earphones often do not: on some
Macs the built in device simply switches its data source from `'ispk'` (internal
speaker) to `'hdpn'` (headphones).

So the code checks both the transport type of every output device and the data
source of anything built in. Virtual and aggregate devices are deliberately
excluded, because those are permanently present on many Macs and treating them as
external would mute Klik forever for no visible reason.

It registers CoreAudio listeners so changes are reported immediately rather than
polled.

### 5.9 Microphone.swift

Answers "is anyone recording right now?"

CoreAudio exposes this directly through a property saying whether a device is
"running somewhere", meaning some process has it open and streaming. Klik checks
every input device.

This covers the case headphone detection cannot: a call on the laptop microphone
and laptop speakers, with no headphones involved at all, where every click goes
into the microphone and out to everyone on the call.

It also watches for new microphones appearing, so a headset connected mid session
is picked up.

### 5.10 GlobalHotKey.swift

Registers Control Option Command M as a system wide mute shortcut, using Carbon's
`RegisterEventHotKey`.

This deliberately does not reuse Klik's own event tap. That tap is listen only, so
it can see the shortcut but cannot swallow it, which would mean the shortcut fires
and an "m" is also typed into whatever you were working in. Carbon claims the
combination properly.

### 5.11 LoginItem.swift

Wraps `SMAppService`. The important detail is that it reports the real status
rather than just whether registration succeeded. macOS can register a login item
and leave it disabled, which it does silently when an app moves, so the interface
needs to know the difference between "registered" and "actually going to run".

### 5.12 Accessibility.swift

Three small functions: check whether Klik is trusted, show the system prompt, and
open the right settings pane.

### 5.13 SelfTest.swift

Command line diagnostics, described in section 11.

---

## 6. Sound packs

### 6.1 The bundled packs

| Pack | Character |
| --- | --- |
| CherryMX Blue (ABS) | Sharp click, the loudest and most recognisable |
| CherryMX Black (ABS) | Linear and firm, brighter of the two Blacks |
| CherryMX Black (PBT) | Linear and firm, deeper |
| CherryMX Brown (PBT) | Tactile bump, muted middle ground |
| CherryMX Red (ABS) | Light and quick, higher pitched |
| Topre Purple Hybrid (PBT) | Soft rounded thock, quite unlike the Cherry switches |
| EG Oreo | Deep and creamy, heavy low end |
| EG Crystal Purple | Bright and glassy, high pitched |

All come from the MechvibesDX collection. For the most obvious contrast, switch
between Blue and Topre.

### 6.2 Adding your own

Put the pack folder here:

```
~/Library/Application Support/Klik/SoundPacks/<pack-name>/
```

Then press Reload in the menu. The Pack Folder button opens that directory.

If the pack ships Ogg audio, which most do, convert it first:

```sh
tools/prepare_pack.sh ~/Library/Application\ Support/Klik/SoundPacks/my-pack
```

This writes a WAV beside the original. Klik prefers the WAV automatically.

### 6.3 Format, version 2

```json
{
  "name": "CherryMX Black - ABS keycaps",
  "id": "keyboad-cherrymx-black-abs",
  "audio_file": "sound.ogg",
  "definition_method": "single",
  "definitions": {
    "KeyA": { "timing": [[31542.0, 31627.0], [31627.0, 31712.0]] }
  },
  "options": { "random_pitch": false, "recommended_volume": 1.0 }
}
```

Keys are W3C `KeyboardEvent.code` names. Each entry has two timings, the first for
the press and the second for the release. Both numbers are timestamps in
milliseconds into the sprite file.

### 6.4 Format, version 1

```json
{
  "name": "Some Old Pack",
  "key_define_type": "single",
  "sound": "sound.ogg",
  "defines": { "30": [31542.0, 85.0] }
}
```

Keys are numeric scancodes. The pair is an offset and a **duration**, not a start
and an end. Multi file packs set `key_define_type` to `multi` and map each key to
a filename instead.

---

## 7. Permissions

### 7.1 Why Accessibility is required

To make a sound when you type in another application, Klik has to see keystrokes
that are not addressed to it. macOS treats that as serious, because a program that
can read every keystroke can read your passwords. So it is a permission only you
can grant, by hand, and no application can grant it to itself.

What Klik does with it: reads which key was pressed, plays a sound, forgets it.
Nothing is stored, written to disk, or transmitted.

### 7.2 Granting it

1. Open System Settings, then Privacy and Security, then Accessibility.
2. Remove any old Klik entries, especially ones pointing at previous locations.
3. Add `/Applications/Klik.app` and switch it on.

Klik polls once a second until the permission appears, then starts the listener
immediately. No relaunch is needed.

### 7.3 Why location matters

macOS remembers this permission for an app **at a specific path**. The build
script deletes and recreates the `build` folder every time, so an app living there
is a moving target. Installing to `/Applications` gives it a permanent home. This
is also why launch at login was silently disabled at one point: it was pointing at
a copy that no longer existed.

---

## 8. Code signing

### 8.1 Why it matters here

Signing is not about distribution in this project. It is about permission.

macOS ties the Accessibility grant to the app's **signature**, so that permission
granted to one program cannot silently transfer to a different one. An ad hoc
signature is built from the file contents, which means every rebuild produces a
completely different signature, and macOS correctly concludes that this is not the
app you approved. The permission disappears on every build.

Signing with any real certificate produces a stable identity, so the grant holds.

### 8.2 What the build script does

`build.sh` picks the first identity it finds, in this order:

1. `KLIK_SIGN_IDENTITY` if set in the environment
2. A Developer ID Application certificate
3. An Apple Development certificate
4. A self signed `Klik Local Signing` certificate
5. Ad hoc, with a warning

### 8.3 Making and backing up a certificate

```sh
tools/create_signing_identity.sh                                  # make one
tools/export_signing_identity.sh ~/Downloads/backup.p12           # back it up
tools/import_signing_identity.sh ~/Downloads/backup.p12           # restore it
```

The Keychain is already the safe place for a certificate: it is encrypted and
unlocked by your login. An exported `.p12` is a portable copy protected only by
the password you choose, and it contains your private key. Anyone holding both the
file and the password can sign software as you, so keep it somewhere you control.

One note on the export script: OpenSSL 3 defaults to an archive format the macOS
keychain importer cannot read, and reports it confusingly as a wrong password. The
`-legacy` flag is required.

---

## 9. Building and installing

```sh
./build.sh install      # build, bundle, sign, copy to /Applications, launch
./build.sh              # build and bundle only
./build.sh run          # build and launch from build/
./build.sh debug        # unoptimised build
```

**Use `install` normally.** Both Accessibility permission and launch at login
remember where the app is, and `build/` is deleted on every build.

The script compiles with Swift Package Manager, then assembles a real application
bundle by hand: the binary into `Contents/MacOS`, `Info.plist` into `Contents`,
and the icon and sound packs into `Contents/Resources`. Only pack audio macOS can
actually decode is copied, so the Ogg originals stay in the source tree. Finally
it signs the bundle.

There is no Xcode project. The package can be opened in Xcode for editing, but the
bundle is produced by this script.

---

## 10. Every menu control

### Master toggle, top left
Silences Klik without quitting it, keeping settings, permission and loaded samples
in place. The menu bar glyph reflects the state.

### Status line
Says `Listening`, the output latency and where sound is going, for example
`Listening, 2.8 ms, speakers`. If Klik is quiet, this line says exactly why:
waiting for permission, listener stopped, muted, microphone in use, headphones
connected, or volume at zero. This is the first place to look when something seems
wrong.

### Mute shortcut label, top right
Shows the global shortcut, Control Option Command M, when it registered
successfully.

### Sound pack
Chooses the recording. Selecting a pack plays it immediately, so you can audition
all eight by moving through the list. The play button replays the current one.

### Volume
Klik's own level, independent of system volume. It shows the effective volume, so
it reads 0 percent while a silence rule is active, and the slider is disabled to
make clear that the value is not being ignored.

### Variation
Per keystroke pitch and gain drift. At zero, playback is identical every time and
the repetition becomes obvious. Around 8 percent is a good setting. Too high and it
sounds like a keyboard with worn switches.

### Sound on key release
Plays the release sample as well as the press. Real switches make noise in both
directions, so this is the more faithful setting.

### Ignore key repeats
When you hold a key and macOS repeats it, this decides whether every repeat
clicks. Holding a real key does not re-actuate the switch, so the default is to
stay quiet.

### Silence during calls
Goes to zero whenever any application is using a microphone.

### Silence when headphones connected
Goes to zero whenever AirPods, Bluetooth speakers, wired earphones, a USB headset
or AirPlay are connected.

### Always use built in speakers
Pins playback to the laptop speakers so typing is heard in the room rather than
inside your headphones, which is how a real keyboard behaves. Note that this
overlaps with the previous switch: if both are on, silence wins whenever
headphones are connected.

### Low latency audio buffer
Requests a 128 frame render quantum instead of the usual 512, worth around 8
milliseconds. This is a device wide setting shared with other applications, and it
applies immediately. Turn it off first if you ever hear crackling elsewhere.

### Launch at login
Registers Klik through `SMAppService`. If macOS registers it but leaves it
disabled, the menu says so. Re-toggle it if you move the app.

### Type a greeting at launch
Types a word to itself when Klik starts, with randomised gaps so it sounds like a
person rather than a metronome. Beyond being decorative, at login it confirms out
loud that the app started, the pack loaded and the speakers work.

### Last key
Live readout of what the listener received. It separates three failures that
otherwise look identical: nothing appearing means the key never reached Klik,
`no sound` means it arrived but the pack has nothing for it, and `played` means
Klik did its job and the problem is elsewhere. It only runs while the menu is open.

### Pack Folder, Reload, Quit
Open the user pack directory, rescan for packs, and exit. Quitting also restores
the audio device's original buffer size.

---

## 11. The self test

```sh
/Applications/Klik.app/Contents/MacOS/Klik --selftest          # silent
/Applications/Klik.app/Contents/MacOS/Klik --demo              # audible
/Applications/Klik.app/Contents/MacOS/Klik --selftest <path>   # a specific pack
```

It reports every pack found and its key count, decode time, the granted buffer
size, whether the built in speakers were pinned, per key durations and peak
amplitudes, all audio devices with their transport and data source, all
microphones and whether any is in use, the measured peak at the mixer, and the
cost of the per keystroke path over 600 calls.

Two checks in there are worth calling out. Peak amplitude catches a pack that
loads perfectly but decodes to silence because the offsets are wrong. The mixer
measurement proves the graph is really producing audio, which separates "producing
nothing" from "producing something you cannot hear".

---

## 12. Problems hit during development

These are the real failures encountered, kept because each one explains a piece of
the design.

### 12.1 Ogg audio cannot be decoded

Nearly every Mechvibes pack ships Ogg Vorbis, which AVFoundation cannot read. A
pack would load successfully and then play nothing. Solved with
`tools/prepare_pack.sh`, converting to WAV with ffmpeg, and a loader that prefers
a WAV sibling automatically.

### 12.2 Command, right Option, right Control and Fn were silent

Not a bug in Klik. Those keys are simply absent from the pack files, because these
are recordings of PC keyboards, which have no Command key, and the author recorded
only one of each modifier pair. Solved with the fallback chain: missing keys borrow
from the most physically similar key present.

### 12.3 The entire function row was silent

A completely different cause with the same symptom. Unless standard function keys
are enabled, the function row sends no key events at all. Brightness and volume
travel as `NX_SYSDEFINED` system events, which the tap was not subscribed to.
Solved by listening on that event type and mapping media keys back to their
function key positions.

### 12.4 Some function keys still silent after that

F1, F2, F11 and F12 worked, being brightness and volume. F3 to F10 did not. Those
are claimed by the window server before a session level tap can see them. Solved
by moving the tap to the HID level, below that point, and adding a catch all so
any unrecognised key still produces a sound.

### 12.5 Accessibility permission kept disappearing

Caused by ad hoc signing, as explained in section 8. Solved by signing with a real
certificate.

### 12.6 Launch at login registered but never ran

The system's records showed the item as disabled. The app was living in `build/`,
which is deleted on every build, so it pointed at something that no longer
existed. Solved by installing to `/Applications`, and by making the interface
report the real status rather than assuming registration means enabled.

### 12.7 The listener died overnight

The most instructive failure. After the Mac slept, Klik went completely silent
while looking perfectly healthy: app running, engine running, pack loaded,
permission granted.

macOS switches event taps off across sleep, screen lock and fast user switching.
It is supposed to send the app a disable event first, and the callback re-enabled
correctly when it did. But after a sleep that event frequently never arrives. The
tap is simply switched off, with no error and no notification, and the app has no
way of finding out unless it asks.

Solved with the watchdog: a check every five seconds plus an immediate check on
wake, re-enabling the tap or rebuilding it entirely if that fails.

This bug was present from the very first build. It only needed a full night of
sleep to appear.

### 12.8 Silence with no visible cause

Klik was reported as not working when every measurement said it was fine. The
cause was that the status line only reported permission and listener problems, so
a mute or an active silence rule still displayed `Listening`. Solved with the
single silence reason property that reports all six causes.

---

## 13. Measured performance

Measured on the development machine, a MacBook Pro running macOS 27:

| Measurement | Result |
| --- | --- |
| Output latency | 2.79 ms |
| Render quantum granted | 128 frames |
| Keystroke path, median | 1.8 to 2.9 us |
| Keystroke path, 99th percentile | 85 to 107 us |
| Keystroke path, maximum | 167 to 214 us |
| Pack decode time | 6 to 16 ms |
| Keys per pack | 96, press and release |
| Peak at mixer during playback | 0.31 to 0.33 |
| Application bundle size | 57 MB |
| Voices in the graph | 24 |

The code between the keypress and the scheduled buffer is around one thousandth of
the total delay. Essentially all of the remaining latency is the audio hardware,
and that is already close to the practical floor.

---

## 14. Troubleshooting

**Start with the status line in the menu.** It names the cause directly.

| Symptom | Cause and fix |
| --- | --- |
| `Waiting for permission` | Grant Accessibility for `/Applications/Klik.app`, removing stale entries first. |
| `Listener stopped, reconnecting` | The watchdog is recovering. If it persists, check Accessibility. |
| `Muted, press ...` | The mute shortcut was pressed. Press it again or use the toggle. |
| `Silent, ... in use` | A microphone is active. Expected during calls. |
| `Silent, ... connected` | Headphones are connected. Expected. |
| `Silent, volume is at 0%` | Raise the volume slider. |
| One key is silent | Open the menu and press it. Nothing in Last key means it never arrived, `no sound` means the pack lacks it. |
| Crackling in other apps | Turn off the low latency audio buffer. |
| Pack fails to load | It is probably Ogg. Run `tools/prepare_pack.sh` on it. |
| Nothing after a rebuild | Check Accessibility, and confirm signing did not fall back to ad hoc. |

For deeper inspection:

```sh
/usr/bin/log show --last 10m --predicate 'subsystem == "com.klik.Klik"'
/Applications/Klik.app/Contents/MacOS/Klik --selftest
```

Note the full path to `log`. Some shells define their own `log` function that
shadows it.

---

## 15. Limitations and future work

**Known limitations**

* No Xcode project. The package opens in Xcode but the bundle comes from the
  script.
* No automated test suite. Verification is the self test, which is a diagnostic
  tool rather than a set of assertions.
* Version 1 pack support was verified against a generated fixture, not against a
  real pack downloaded from the community library.
* Extended key codes in version 1 packs are genuinely ambiguous. Klik tries
  several candidate encodings, which is a best effort rather than a guarantee.
* Pack preview switches and then plays, rather than playing without switching.
  Switching takes about 10 milliseconds and is reversible, so the outcome is
  similar, but it is not literally preview before commit.
* The greeting only plays letters, digits and spaces. Punctuation is skipped.
* HDMI and DisplayPort count as external audio, so a connected monitor with
  speakers will silence Klik. Turn the switch off if that is unwanted.

**Reasonable next steps**

* Per application rules, silencing Klik in chosen applications.
* A pack maker that turns your own recordings into a pack, which is the one item
  from the original brief that remains unimplemented.
* True preview, holding a second pack in memory alongside the active one.
* A real Xcode project, if editing in Xcode's interface is wanted.
