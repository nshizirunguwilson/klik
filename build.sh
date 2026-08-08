#!/usr/bin/env bash
# Builds Klik and assembles it into a runnable .app bundle.
#
#   ./build.sh          release build
#   ./build.sh debug    debug build
#   ./build.sh run      build, then relaunch the app

set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
RUN=false
INSTALL=false
case "${1:-}" in
  debug)   CONFIG=debug ;;
  run)     RUN=true ;;
  install) INSTALL=true; RUN=true ;;
  "")      ;;
  *)       echo "usage: $0 [debug|run|install]" >&2; exit 1 ;;
esac

APP="build/Klik.app"
CONTENTS="$APP/Contents"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/Klik"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/Klik"
cp Resources/Info.plist "$CONTENTS/Info.plist"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "==> Drawing app icon"
  swift tools/make_icon.swift
fi
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

if [[ -d SoundPacks ]]; then
  mkdir -p "$CONTENTS/Resources/SoundPacks"
  # Only the pack files the app actually reads -- the .ogg originals stay in the
  # source tree, since AVAudioFile cannot decode them anyway.
  for pack in SoundPacks/*/; do
    name=$(basename "$pack")
    [[ -f "$pack/config.json" ]] || continue
    mkdir -p "$CONTENTS/Resources/SoundPacks/$name"
    cp "$pack/config.json" "$CONTENTS/Resources/SoundPacks/$name/"
    find "$pack" -maxdepth 1 \( -name '*.wav' -o -name '*.mp3' -o -name '*.m4a' -o -name '*.aiff' -o -name '*.caf' \) \
      -exec cp {} "$CONTENTS/Resources/SoundPacks/$name/" \;
  done
fi

# Signing identity, best first.
#
# This is not about distribution -- it is about Accessibility permission. macOS
# keys that permission to the app's signature, so a signature that changes on
# every build means re-granting it on every build. Any real certificate stays the
# same and the grant sticks; ad-hoc does not.
pick_identity() {
  if [[ -n "${KLIK_SIGN_IDENTITY:-}" ]]; then
    echo "$KLIK_SIGN_IDENTITY"; return
  fi
  local identities
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for preferred in "Developer ID Application" "Apple Development" "Klik Local Signing"; do
    local found
    found=$(echo "$identities" | grep -o "\"$preferred[^\"]*\"" | head -1 | tr -d '"')
    if [[ -n "$found" ]]; then echo "$found"; return; fi
  done
  echo "-"
}

IDENTITY=$(pick_identity)
if [[ "$IDENTITY" == "-" ]]; then
  echo "==> Signing (ad-hoc: Accessibility permission will reset on each build)"
  echo "    Run tools/create_signing_identity.sh once to stop that."
else
  echo "==> Signing as: $IDENTITY"
fi
codesign --force --sign "$IDENTITY" --identifier com.klik.Klik "$APP"

echo "==> Built $APP"

# Launch at login records where the app is, and this script deletes and rebuilds
# build/ every time. Installing to /Applications gives it somewhere stable to
# point at -- and keeps Accessibility pointed at one copy instead of several.
if $INSTALL; then
  echo "==> Installing to /Applications"
  pkill -x Klik 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Klik.app
  cp -R "$APP" /Applications/Klik.app
  APP="/Applications/Klik.app"
fi

if $RUN; then
  echo "==> Relaunching"
  pkill -x Klik 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
