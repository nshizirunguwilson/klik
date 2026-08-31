# Running and maintaining Klik

Everything about keeping Klik installed, updated and working on your Mac.
[Artifact Link](https://claude.ai/code/artifact/493fff16-6327-4007-9b21-f0ac89d4149e)

`README.md` covers what Klik is. `DOCUMENTATION.md` covers how it works inside.
This file covers living with it.

Last verified: 1 September 2026, on this machine.

---

## Contents

1. [Where Klik lives](#1-where-klik-lives)
2. [Updating Klik](#2-updating-klik)
3. [What survives an update](#3-what-survives-an-update)
4. [Checking everything is fine](#4-checking-everything-is-fine)
5. [The three tests](#5-the-three-tests)
6. [Reading the log](#6-reading-the-log)
7. [When something is wrong](#7-when-something-is-wrong)
8. [Setting up on a new Mac](#8-setting-up-on-a-new-mac)
9. [Quick reference](#9-quick-reference)

---

## 1. Where Klik lives

Klik is not installed the way big applications are. There is no installer, no
hidden system copy, no background service registered somewhere you cannot see.

It is one folder:

```text
/Applications/Klik.app
```

Inside that folder sits the compiled program, the icon and the sound packs. That
folder **is** the app. Updating Klik means replacing that folder, and nothing
else.

Three things deliberately live **outside** the folder. This is the reason
updating is safe.

| What | Where it lives | Survives an update |
| --- | --- | --- |
| Your settings | `~/Library/Preferences/com.klik.Klik.plist` | Yes |
| Accessibility permission | The macOS permission database | Yes, see section 3 |
| Launch at login | The macOS login item records | Yes |

There is also a second copy of the app at `build/Klik.app` inside the project
folder. That one is scratch. It is deleted and rebuilt every single time you
build, and nothing points at it. Ignore it.

---

## 2. Updating Klik

There are two build commands and **only one of them updates the app you
actually use**. This is the single most important thing in this file.

| Command | What it does |
| --- | --- |
| `./build.sh` | Compiles and builds `build/Klik.app` only. Your installed app is untouched. |
| `./build.sh install` | Compiles, builds, then replaces `/Applications/Klik.app` and relaunches it. |

**Always use `./build.sh install`.**

If you change the code and run plain `./build.sh`, your menu bar keeps running
the old version and nothing tells you. You will be looking at a fix that is not
actually running.

### What install does, step by step

```text
1. Compiles the Swift source
2. Assembles build/Klik.app with the icon and sound packs
3. Signs it with your Apple Development certificate
4. Quits the running Klik
5. Deletes the old /Applications/Klik.app
6. Copies the new build into its place
7. Launches it again
```

Steps 4 to 6 are the whole update. Because the app is just a folder, replacing
the folder is all an update can be.

### Other build options

| Command | When to use it |
| --- | --- |
| `./build.sh` | Compiling to check the code builds, without disturbing the running app. |
| `./build.sh debug` | A debug build, slower but easier to diagnose. |
| `./build.sh run` | Builds and relaunches from `build/`, without installing. |
| `./build.sh install` | The normal one. Updates the app you use. |

---

## 3. What survives an update

Everything you have set up. Here is exactly why, so you do not have to take it
on trust.

### Your settings

They are stored in a plist file that lives in your home folder, completely
outside the app:

```sh
defaults read com.klik.Klik
```

That prints your volume, chosen pack, variation amount and every toggle. The
install step never touches that file, so replacing the app cannot lose them.

### Accessibility permission

This is the one that used to break, so it is worth understanding.

macOS ties Accessibility permission to two things:

- The app's **code signature**
- The app's **location on disk**

Both stay the same across an update. The build always signs with the same Apple
Development certificate, and install always writes to the same
`/Applications/Klik.app` path. So the permission holds.

You can confirm which certificate was used:

```sh
codesign -dv --verbose=2 /Applications/Klik.app 2>&1 | grep Authority
```

You want to see `Apple Development: ...`. If it ever says **adhoc** instead, the
signature changes on every build and macOS treats each build as a brand new app
that has to earn its permission again. That was an early problem in this
project, and section 8 of `DOCUMENTATION.md` explains it fully.

### Launch at login

This points at a path, and the path does not change:

```sh
sfltool dumpbtm | grep -A9 -i klik
```

You want `Disposition: [enabled, ...]` and `URL: /Applications/Klik.app`.

This is also why the app must live in `/Applications` and not in `build/`. The
build folder is deleted on every build, so a login item pointing there would be
pointing at something that no longer exists.

---

## 4. Checking everything is fine

Five checks. Run them any time you are unsure whether an update actually landed.

### Is the running app the installed one?

```sh
ps -Ao pid,lstart,comm | grep "[K]lik.app"
```

The path should be `/Applications/Klik.app/Contents/MacOS/Klik`. If it says
`build/` instead, you are running the scratch copy, not the installed one.

### Is the installed app the new build?

```sh
stat -f "%Sm" /Applications/Klik.app/Contents/MacOS/Klik
```

The time should match when you last ran `./build.sh install`.

### Do the two copies match?

```sh
shasum /Applications/Klik.app/Contents/MacOS/Klik build/Klik.app/Contents/MacOS/Klik
```

Two identical hashes means the installed app really is the build you just made.
Different hashes means you ran `./build.sh` without `install`.

### Are your settings intact?

```sh
defaults read com.klik.Klik
```

### Is the permission still granted?

Open the menu. If the status line says `Waiting for permission`, it is not.
Otherwise it is.

---

## 5. The three tests

All three run from the command line and none of them need the menu.

```sh
/Applications/Klik.app/Contents/MacOS/Klik --demo        # audible
/Applications/Klik.app/Contents/MacOS/Klik --selftest    # silent
/Applications/Klik.app/Contents/MacOS/Klik --devicetest  # audible
```

### `--demo`

Types the word "klik" through the audio engine. The fastest way to answer "is
sound coming out at all".

### `--selftest`

Reports every pack found and its key count, decode time, the render quantum the
output device granted, per key durations and peak amplitudes, every audio device
with its transport, every microphone and whether it is in use, and the cost of
the per keystroke path over 600 calls.

Ends in `OK` or `FAIL`. Two checks in it matter most. Peak amplitude catches a
pack that loads perfectly but decodes to silence. The mixer measurement proves
the graph is genuinely producing audio.

### `--devicetest`

The one that guards the headphone bug fixed on 31 August 2026.

It needs a second output device connected, otherwise it skips. It switches your
system output back and forth, pins and unpins the built in speakers, connects
and disconnects repeatedly, and measures what actually comes out at every step.
**It puts your original output device back when it finishes.**

Run this after any change to `AudioEngine.swift` or `OutputDevices.swift`.

A healthy run ends with:

```text
OK  sound survived every device change
```

---

## 6. Reading the log

```sh
/usr/bin/log show --predicate 'subsystem == "com.klik.Klik"' --last 30m --style compact
```

**Use the full path `/usr/bin/log`.** Some shells define their own `log`
function that shadows it and fails with a confusing error.

Useful things to search for:

| Message | Meaning |
| --- | --- |
| `Engine started` | The audio engine came up at launch. |
| `Event tap installed` | The keyboard listener is running. |
| `Restarted (audio devices changed)` | A device connected or disconnected and the engine rebuilt. Normal and healthy. |
| `Engine drifted` | The five second health check found a problem and is fixing it. |
| `Restart failed` | An output device refused to start. The app retries, waiting longer each time. |
| `External audio` | An external listening device appeared or went away. |
| `Filled N keys the pack does not define` | Normal. Missing keys borrowed a sound from a similar key. |

---

## 7. When something is wrong

**Start with the status line in the menu.** It names the cause directly rather
than making you guess.

| Status line says | What to do |
| --- | --- |
| `Waiting for permission` | Grant Accessibility for `/Applications/Klik.app`. Remove any stale Klik entries first. |
| `Listener stopped, reconnecting` | The watchdog is already recovering. If it persists, check Accessibility. |
| `Sound output is not responding` | An output device is refusing to start. Klik keeps retrying by itself, waiting longer each time. |
| `Muted, press ...` | The mute shortcut was pressed. Press Control Option Command M again. |
| `Silent, ... in use` | A microphone is live. Expected during calls. |
| `Silent, ... connected` | Headphones are connected and the headphone silence rule is on. |
| `Silent, volume is at 0%` | Raise the volume slider. |

Other symptoms:

| Symptom | Cause and fix |
| --- | --- |
| One key is silent | Open the menu and press it. Nothing in `Last key` means it never reached Klik. `no sound` means the pack has nothing for it. |
| Silent after connecting headphones | Should not happen since the fix on 31 August 2026. Run `--devicetest` to confirm, and check the status line. |
| Nothing changed after rebuilding | You almost certainly ran `./build.sh` instead of `./build.sh install`. Compare the hashes in section 4. |
| Crackling in other apps | Turn off the low latency audio buffer in the menu. |
| A pack fails to load | It is probably still Ogg. Run `tools/prepare_pack.sh` on it. |
| Permission lost after a rebuild | Check the signing authority in section 3. If it fell back to adhoc, the certificate is missing. |
| App is completely silent, no obvious reason | Run `--selftest` first, then `--devicetest`. Between them they cover packs, decoding, the graph and device switching. |

---

## 8. Setting up on a new Mac

The project is on GitHub, so nothing here depends on this particular machine.

```sh
git clone https://github.com/nshizirunguwilson/klik.git
cd klik
```

### Step 1: prepare the sound packs

**Do this first.** The prepared `.wav` files are generated and are deliberately
not stored in git, because they are large. A fresh clone therefore has packs
holding only an `.ogg` file, which macOS cannot decode. Build without this step
and you get an app that runs perfectly and makes no sound at all.

```sh
brew install ffmpeg
tools/prepare_pack.sh SoundPacks/*
```

The build warns you by name about any pack that would ship silent, so you will
be told if you forget.

### Step 2: sort out signing

If you have an Apple Development certificate in your keychain, the build finds
and uses it automatically. Nothing to do.

If you do not, make a local one:

```sh
tools/create_signing_identity.sh
```

Either way, the point is a signature that stays the same between builds, so
Accessibility permission is granted once rather than every time. See section 8
of `DOCUMENTATION.md`.

### Step 3: build and install

```sh
./build.sh install
```

### Step 4: grant Accessibility

Open the menu, click **Open Privacy Settings**, and enable Klik under
Privacy and Security, then Accessibility. It starts working immediately, with no
relaunch.

### Step 5: turn on launch at login

In the menu. macOS may ask you to approve it in Login Items.

### Step 6: confirm

```sh
/Applications/Klik.app/Contents/MacOS/Klik --selftest
/Applications/Klik.app/Contents/MacOS/Klik --devicetest
```

---

## 9. Quick reference

```sh
# Update the app you actually use
./build.sh install

# Check the three tests
/Applications/Klik.app/Contents/MacOS/Klik --demo
/Applications/Klik.app/Contents/MacOS/Klik --selftest
/Applications/Klik.app/Contents/MacOS/Klik --devicetest

# Read the log
/usr/bin/log show --predicate 'subsystem == "com.klik.Klik"' --last 30m --style compact

# Your settings
defaults read com.klik.Klik

# Which app is running
ps -Ao pid,lstart,comm | grep "[K]lik.app"

# Confirm installed and built copies match
shasum /Applications/Klik.app/Contents/MacOS/Klik build/Klik.app/Contents/MacOS/Klik

# Signing certificate used
codesign -dv --verbose=2 /Applications/Klik.app 2>&1 | grep Authority

# Launch at login state
sfltool dumpbtm | grep -A9 -i klik
```

### The three rules

1. **`./build.sh install`, never plain `./build.sh`.** Only install updates the
   app you use.
2. **Keep it at `/Applications/Klik.app`.** Permission and launch at login are
   both tied to that path.
3. **Keep signing with a real certificate.** An adhoc signature loses your
   Accessibility permission on every single build.
