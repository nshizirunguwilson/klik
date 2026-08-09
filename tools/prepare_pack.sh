#!/usr/bin/env bash
# Converts a sound pack's audio file to WAV.
#
# AVAudioFile cannot decode Ogg Vorbis, which is what most Mechvibes packs ship.
# Klik decodes the whole sprite into memory at launch, so the on-disk format only
# matters for load time -- WAV keeps that path dependency-free.
#
# Usage: tools/prepare_pack.sh SoundPacks/cherrymx-black-abs [...]

set -euo pipefail

if ! command -v ffmpeg >/dev/null; then
  echo "ffmpeg not found. Install it with: brew install ffmpeg" >&2
  exit 1
fi

for pack in "$@"; do
  config="$pack/config.json"
  if [[ ! -f "$config" ]]; then
    echo "skip $pack (no config.json)" >&2
    continue
  fi

  audio=$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("audio_file") or c.get("sound") or "")
' "$config")

  if [[ -z "$audio" ]]; then
    echo "skip $pack (single audio file not declared; multi-file packs need no conversion)" >&2
    continue
  fi

  src="$pack/$audio"
  dst="$pack/${audio%.*}.wav"

  if [[ ! -f "$src" ]]; then
    echo "skip $pack (missing $audio)" >&2
    continue
  fi

  if [[ "$src" == "$dst" ]]; then
    echo "ok   $pack (already WAV)"
    continue
  fi

  ffmpeg -v error -y -i "$src" -c:a pcm_s16le "$dst"
  echo "ok   $pack -> $(basename "$dst") ($(du -h "$dst" | cut -f1))"
done
