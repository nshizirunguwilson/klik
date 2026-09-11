#!/usr/bin/env python3
"""Levels every sound pack to the same loudness.

Packs come from different places -- some recorded off a real keyboard at
whatever gain the author used, some synthesised here -- and measured across the
set they span about 24 dB. That is not a small thing when the packs are meant to
be compared: switching from EG Oreo to Deep Thock was mostly a jump in volume,
which drowns out the difference in character that you are actually trying to
hear, and means the volume slider has to be re-set after every change.

So each pack's `options.recommended_volume` is set from a measurement of its own
'A' key, and `AudioEngine` applies it when the pack is loaded. Nothing is
re-recorded and no sample is touched: it is one number per config file.

    python3 tools/level_packs.py            report only
    python3 tools/level_packs.py --write    update the config files
"""

import array
import json
import math
import os
import sys
import wave

# Chosen to sit near the loudest recorded pack, so quiet packs are brought up
# rather than everything being dragged down to the quietest one.
TARGET_RMS = 0.05
# A pack that would need more than this is too quiet to rescue by gain alone,
# and pushing further would only raise its noise floor.
MAX_GAIN = 4.5
MIN_GAIN = 0.2
# Matches `limiterKnee` in AudioEngine.swift.
HEADROOM = 0.7


def load_mono(path):
    with wave.open(path, "rb") as w:
        channels = w.getnchannels()
        frames = w.readframes(w.getnframes())
    samples = array.array("h")
    samples.frombytes(frames)
    if channels == 2:
        samples = samples[::2]
    return [v / 32768.0 for v in samples]


def measure(directory, config):
    audio = config.get("audio_file") or config.get("sound")
    wav = os.path.join(directory, os.path.splitext(audio)[0] + ".wav")
    if not os.path.exists(wav):
        return None
    signal = load_mono(wav)
    rate = wave.open(wav, "rb").getframerate()

    # Average over a handful of ordinary keys rather than trusting one, since
    # pack authors do not all record at a steady hand.
    probes = ["KeyA", "KeyS", "KeyD", "KeyF", "KeyJ", "KeyK"]
    definitions = config.get("definitions", {})
    energies, peaks = [], []
    for key in probes:
        timing = definitions.get(key, {}).get("timing")
        if not timing:
            continue
        start, end = int(timing[0][0] / 1000 * rate), int(timing[0][1] / 1000 * rate)
        segment = signal[start:min(end, len(signal))]
        if len(segment) < 64:
            continue
        energies.append(sum(v * v for v in segment) / len(segment))
        peaks.append(max(abs(v) for v in segment))
    if not energies:
        return None
    return math.sqrt(sum(energies) / len(energies)), max(peaks)


def main():
    write = "--write" in sys.argv
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    packs_root = os.path.join(root, "SoundPacks")

    print(f"{'pack':<34s}{'rms':>8s}{'peak':>8s}{'gain':>8s}")
    for name in sorted(os.listdir(packs_root)):
        directory = os.path.join(packs_root, name)
        config_path = os.path.join(directory, "config.json")
        if not os.path.isfile(config_path):
            continue
        config = json.load(open(config_path))
        measured = measure(directory, config)
        if measured is None:
            print(f"{name:<34s}   no audio to measure")
            continue
        rms, peak = measured
        gain = max(MIN_GAIN, min(MAX_GAIN, TARGET_RMS / max(rms, 1e-6)))
        # Keep a single keystroke below the mixer's limiter knee, so one key at
        # a time is never shaped at all and only real overlap is. Saturation is
        # a change of timbre, and a pack that is quietly being squashed on every
        # press does not sound like the pack it is meant to be.
        gain = min(gain, HEADROOM / max(peak, 1e-6))
        gain = round(gain, 3)
        print(f"{name:<34s}{rms:8.4f}{peak:8.3f}{gain:8.2f}")

        if write:
            config.setdefault("options", {})["recommended_volume"] = gain
            with open(config_path, "w") as out:
                json.dump(config, out, indent=2)
                out.write("\n")

    if not write:
        print("\n(report only -- pass --write to update the config files)")


if __name__ == "__main__":
    main()
