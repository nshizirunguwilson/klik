#!/usr/bin/env python3
"""Synthesises Klik's distinct sound packs.

Klik shipped with eight packs recorded from real switches, and six of them
measured almost identically: spectral centroid between 2.8 and 5.5 kHz, every
sample a 50-100 ms broadband click. They are all faithful recordings, and in a
menu they are indistinguishable -- picking one over another is not a choice
anybody can make by ear.

These are built the other way round: each pack is designed to be unmistakable
against every other one, along axes you can actually hear.

    register    from a 110 Hz thock to a 6 kHz tap
    tonality    from a pure sine to pure noise
    length      from a 25 ms tick to a 400 ms ring
    attack      from a soft puff to a hard metallic strike

Run it from the repository root; it writes SoundPacks/<id>/{sound.wav,config.json}.
No third-party modules -- everything below is arithmetic on a list of floats.

    python3 tools/make_sound_packs.py
"""

import json
import math
import os
import random
import struct
import wave

RATE = 44100

# ---------------------------------------------------------------- primitives


def silence(seconds):
    return [0.0] * int(seconds * RATE)


def noise(seconds, rng):
    return [rng.uniform(-1.0, 1.0) for _ in range(int(seconds * RATE))]


def decay_envelope(samples, seconds, curve=4.0):
    """Exponential fall from 1 to ~0 over `seconds`."""
    n = max(1, int(seconds * RATE))
    return [s * math.exp(-curve * i / n) if i < n else 0.0
            for i, s in enumerate(samples)]


def attack(samples, seconds=0.0008):
    """Rounds off the very start so the onset is a hit, not a digital edge."""
    n = max(1, int(seconds * RATE))
    out = list(samples)
    for i in range(min(n, len(out))):
        out[i] *= i / n
    return out


def tail(samples, seconds=0.004):
    """Fades the last few milliseconds to zero so slices never end on a step."""
    n = max(1, int(seconds * RATE))
    out = list(samples)
    for i in range(min(n, len(out))):
        out[len(out) - 1 - i] *= i / n
    return out


def _svf(samples, corner, resonance, pick):
    """Chamberlin state-variable filter, one pass.

    The coefficients need clamping and it is not a detail. This topology is only
    stable while `f + q < 2`, which puts a hard ceiling near a sixth of the
    sample rate. Ask it for 8 kHz at 44.1 kHz and it does not roll off, it
    oscillates: the first version of the Paper Tap pack came out as 20 kHz hiss
    that measured bright and was inaudible on a laptop speaker.
    """
    f = 2 * math.sin(math.pi * min(corner, RATE / 6.2) / RATE)
    q = 1.0 / max(0.5, resonance)
    f = min(f, max(0.05, 1.9 - q))
    low = band = 0.0
    out = []
    for x in samples:
        high = x - low - q * band
        band += f * high
        low += f * band
        out.append({"low": low, "band": band, "high": high}[pick])
    return out


def lowpass(samples, cutoff, resonance=0.7):
    return _svf(samples, cutoff, resonance, "low")


def bandpass(samples, centre, resonance=4.0):
    return _svf(samples, centre, resonance, "band")


def highpass(samples, cutoff, resonance=0.7):
    return _svf(samples, cutoff, resonance, "high")


def modes(partials, seconds, base):
    """Modal synthesis: a sum of exponentially decaying sinusoids.

    `partials` is a list of (frequency ratio, amplitude, decay multiplier).
    Harmonic ratios read as wood or a struck string; inharmonic ones as glass
    or metal. This is what gives each pack a fixed, recognisable timbre where a
    noise burst would just sound like every other click.
    """
    n = int(seconds * RATE)
    out = [0.0] * n
    for ratio, amp, damp in partials:
        freq = base * ratio
        if freq >= RATE * 0.45:
            continue
        step = 2 * math.pi * freq / RATE
        fall = 1.0 / max(1e-4, seconds * damp)
        for i in range(n):
            out[i] += amp * math.sin(step * i) * math.exp(-fall * i / RATE * 4)
    return out


def sweep(start_hz, end_hz, seconds, shape="sine", curve=3.0):
    """An oscillator whose pitch glides, which is what makes a drop a drop."""
    n = int(seconds * RATE)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / max(1, n - 1)
        freq = start_hz * math.pow(end_hz / start_hz, 1 - math.exp(-curve * t))
        phase += 2 * math.pi * freq / RATE
        if shape == "sine":
            out.append(math.sin(phase))
        elif shape == "square":
            out.append(1.0 if math.sin(phase) >= 0 else -1.0)
        else:  # triangle
            out.append(2 / math.pi * math.asin(max(-1.0, min(1.0, math.sin(phase)))))
    return out


def stepped_blip(steps, seconds, shape="square"):
    """A pitch that jumps rather than glides -- the 8-bit sound."""
    out = []
    phase = 0.0
    per = seconds / len(steps)
    for freq in steps:
        for _ in range(int(per * RATE)):
            phase += 2 * math.pi * freq / RATE
            if shape == "square":
                out.append(1.0 if math.sin(phase) >= 0 else -1.0)
            else:
                out.append(math.sin(phase))
    return out


def mix(*layers):
    longest = max(len(layer) for layer in layers)
    out = [0.0] * longest
    for layer in layers:
        for i, value in enumerate(layer):
            out[i] += value
    return out


def gain(samples, amount):
    return [s * amount for s in samples]


def normalise(samples, peak=0.72):
    top = max((abs(s) for s in samples), default=0.0)
    if top < 1e-9:
        return samples
    return [s * peak / top for s in samples]


def finish(samples, peak=0.72):
    return tail(attack(normalise(samples, peak)))


# ------------------------------------------------------------------- designs
#
# Each builder takes a role and returns one sample. The roles exist because a
# keyboard where the spacebar sounds exactly like the J key reads as fake --
# big keys are heavier, modifiers are duller, and a release is always quieter
# than the press that caused it.

ROLES = ["normal0", "normal1", "normal2", "normal3",
         "space", "enter", "backspace", "modifier"]


def role_shape(role):
    """(pitch multiplier, length multiplier, loudness) for each key group."""
    return {
        "normal0": (1.00, 1.00, 1.00),
        "normal1": (1.06, 0.96, 0.94),
        "normal2": (0.94, 1.05, 1.02),
        "normal3": (1.02, 0.92, 0.90),
        "space": (0.72, 1.30, 1.00),
        "enter": (0.84, 1.15, 0.98),
        "backspace": (1.12, 0.90, 0.88),
        "modifier": (0.90, 0.85, 0.72),
    }[role]


def typewriter(role, release, rng):
    pitch, length, loud = role_shape(role)
    seconds = 0.13 * length * (0.5 if release else 1.0)
    hammer = decay_envelope(bandpass(noise(seconds, rng), 3200 * pitch, 2.0), seconds, 22)
    metal = modes([(1.0, 1.0, 1.0), (2.71, 0.55, 1.4), (4.32, 0.30, 2.0), (6.9, 0.14, 3.0)],
                  seconds, 1180 * pitch)
    body = decay_envelope(lowpass(noise(seconds, rng), 300 * pitch, 3.0), seconds, 30)
    out = mix(gain(hammer, 0.9), gain(metal, 0.5), gain(body, 1.6))
    return finish(out, 0.75 * loud * (0.42 if release else 1.0))


def water_drop(role, release, rng):
    pitch, length, loud = role_shape(role)
    seconds = 0.17 * length * (0.55 if release else 1.0)
    drop = decay_envelope(sweep(380 * pitch, 1500 * pitch, seconds, "sine", 5.0), seconds, 5.5)
    plip = decay_envelope(bandpass(noise(0.01, rng), 2600 * pitch, 3.0), 0.01, 40)
    out = mix(gain(drop, 1.0), gain(plip, 0.35))
    return finish(out, 0.7 * loud * (0.45 if release else 1.0))


def bubble_pop(role, release, rng):
    pitch, length, loud = role_shape(role)
    seconds = 0.05 * length * (0.6 if release else 1.0)
    pop = decay_envelope(sweep(2100 * pitch, 780 * pitch, seconds, "sine", 6.0), seconds, 9)
    air = decay_envelope(highpass(noise(0.006, rng), 4000, 1.0), 0.006, 45)
    out = mix(gain(pop, 1.0), gain(air, 0.25))
    return finish(out, 0.7 * loud * (0.42 if release else 1.0))


def wood_block(role, release, rng):
    pitch, length, loud = role_shape(role)
    seconds = 0.1 * length * (0.55 if release else 1.0)
    knock = modes([(1.0, 1.0, 1.0), (1.72, 0.62, 1.5), (3.14, 0.32, 2.2), (5.1, 0.12, 3.4)],
                  seconds, 430 * pitch)
    stick = decay_envelope(bandpass(noise(0.008, rng), 1900 * pitch, 2.5), 0.008, 35)
    out = mix(gain(knock, 1.0), gain(stick, 0.45))
    return finish(out, 0.72 * loud * (0.44 if release else 1.0))


def glass_bell(role, release, rng):
    pitch, length, loud = role_shape(role)
    seconds = 0.42 * length * (0.45 if release else 1.0)
    # Deliberately inharmonic -- the ratios of a struck bar, not a string.
    ring = modes([(1.0, 1.0, 1.0), (2.76, 0.62, 1.25), (5.40, 0.34, 1.7), (8.93, 0.16, 2.4)],
                 seconds, 1080 * pitch)
    strike = decay_envelope(highpass(noise(0.006, rng), 5200, 1.0), 0.006, 50)
    out = mix(gain(ring, 1.0), gain(strike, 0.3))
    return finish(out, 0.68 * loud * (0.4 if release else 1.0))


def deep_thock(role, release, rng):
    pitch, length, loud = role_shape(role)
    seconds = 0.11 * length * (0.6 if release else 1.0)
    body = modes([(1.0, 1.0, 1.0), (2.1, 0.35, 2.0)], seconds, 118 * pitch)
    thud = decay_envelope(lowpass(noise(seconds, rng), 520 * pitch, 1.6), seconds, 26)
    out = mix(gain(body, 1.0), gain(thud, 0.8))
    # Nothing above 1.5 kHz survives, which is the whole character.
    return finish(lowpass(out, 1500, 0.7), 0.8 * loud * (0.45 if release else 1.0))


def retro_blip(role, release, rng):
    pitch, length, loud = role_shape(role)
    seconds = 0.075 * length * (0.55 if release else 1.0)
    base = 880 * pitch
    steps = [base * 1.5, base, base * 0.75] if not release else [base * 0.75, base * 0.5]
    blip = decay_envelope(stepped_blip(steps, seconds, "square"), seconds, 5)
    out = lowpass(blip, 5200, 0.8)
    return finish(out, 0.55 * loud * (0.45 if release else 1.0))


def paper_tap(role, release, rng):
    pitch, length, loud = role_shape(role)
    seconds = 0.028 * length * (0.7 if release else 1.0)
    # Centred where a fingernail on card actually sits. Pushed any higher this
    # becomes hiss, which is inaudible on a laptop speaker rather than quiet.
    tap = decay_envelope(bandpass(noise(seconds, rng), 2600 * pitch, 3.0), seconds, 40)
    rustle = decay_envelope(bandpass(noise(seconds, rng), 4600 * pitch, 3.0), seconds, 28)
    out = lowpass(mix(gain(tap, 1.0), gain(rustle, 0.35)), 6800, 0.7)
    return finish(out, 0.62 * loud * (0.5 if release else 1.0))


PACKS = [
    ("klik-deep-thock", "Deep Thock", deep_thock,
     "Low and muffled, nothing above 1.5 kHz."),
    ("klik-wood-block", "Wood Block", wood_block,
     "A hollow harmonic knock, like a rimshot block."),
    ("klik-typewriter", "Typewriter", typewriter,
     "Hard metallic strike over a heavy carriage thunk."),
    ("klik-glass-bell", "Glass Bell", glass_bell,
     "Inharmonic partials that ring on for a third of a second."),
    ("klik-water-drop", "Water Drop", water_drop,
     "A pure tone sliding upward. No click at all."),
    ("klik-bubble-pop", "Bubble Pop", bubble_pop,
     "Short, high, and falling in pitch."),
    ("klik-retro-blip", "Retro Blip", retro_blip,
     "Stepped square waves, unapologetically 8-bit."),
    ("klik-paper-tap", "Paper Tap", paper_tap,
     "Dry filtered noise, 25 ms, no pitch whatsoever."),
]


# --------------------------------------------------------------- key mapping

W3C_KEYS = [
    "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI",
    "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR",
    "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ",
    "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6",
    "Digit7", "Digit8", "Digit9",
    "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash", "Semicolon",
    "Quote", "Backquote", "Comma", "Period", "Slash", "IntlBackslash",
    "Escape", "Tab", "CapsLock", "Space", "Enter", "Backspace", "Delete",
    "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight",
    "AltLeft", "AltRight", "MetaLeft", "MetaRight", "Fn",
    "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
    "Home", "End", "PageUp", "PageDown", "Insert",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20",
    "NumLock", "NumpadDivide", "NumpadMultiply", "NumpadSubtract",
    "NumpadAdd", "NumpadEnter", "NumpadDecimal", "NumpadEqual",
    "Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4",
    "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9",
]

BIG_KEYS = {"Space": "space", "Enter": "enter", "NumpadEnter": "enter",
            "Backspace": "backspace", "Delete": "backspace"}

MODIFIER_KEYS = {
    "Escape", "Tab", "CapsLock", "ShiftLeft", "ShiftRight",
    "ControlLeft", "ControlRight", "AltLeft", "AltRight",
    "MetaLeft", "MetaRight", "Fn", "NumLock",
    "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
    "Home", "End", "PageUp", "PageDown", "Insert",
} | {f"F{n}" for n in range(1, 21)}


def role_for(key):
    if key in BIG_KEYS:
        return BIG_KEYS[key]
    if key in MODIFIER_KEYS:
        return "modifier"
    # Spread the ordinary keys over the four variants so neighbouring letters
    # are not identical. Deterministic, so rebuilding gives the same pack.
    return f"normal{sum(ord(c) for c in key) % 4}"


# ------------------------------------------------------------------- writing


def build_pack(pack_id, name, builder, blurb, root):
    rng = random.Random(hash(pack_id) & 0xFFFF)
    sprite = []
    timings = {}
    gap = silence(0.04)

    for role in ROLES:
        for release in (False, True):
            sample = builder(role, release, rng)
            start = len(sprite) / RATE
            sprite.extend(sample)
            end = len(sprite) / RATE
            sprite.extend(gap)
            timings[(role, release)] = (round(start * 1000, 2), round(end * 1000, 2))

    directory = os.path.join(root, "SoundPacks", pack_id)
    os.makedirs(directory, exist_ok=True)

    with wave.open(os.path.join(directory, "sound.wav"), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        frames = bytearray()
        for value in sprite:
            clipped = max(-1.0, min(1.0, value))
            frames += struct.pack("<h", int(clipped * 32767))
        out.writeframes(bytes(frames))

    definitions = {}
    for key in W3C_KEYS:
        role = role_for(key)
        definitions[key] = {
            "timing": [list(timings[(role, False)]), list(timings[(role, True)])]
        }

    config = {
        "id": pack_id,
        "name": name,
        "description": blurb,
        "audio_file": "sound.wav",
        "includes_numpad": True,
        "options": {"random_pitch": False, "recommended_volume": 1.0},
        "definitions": definitions,
    }
    with open(os.path.join(directory, "config.json"), "w") as out:
        json.dump(config, out, indent=2)
        out.write("\n")

    return len(sprite) / RATE


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for pack_id, name, builder, blurb in PACKS:
        seconds = build_pack(pack_id, name, builder, blurb, root)
        print(f"  {name:<14s} {pack_id:<20s} {seconds:4.1f}s sprite  {blurb}")


if __name__ == "__main__":
    print("Building sound packs")
    main()
