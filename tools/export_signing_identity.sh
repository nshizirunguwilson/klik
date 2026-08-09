#!/usr/bin/env bash
# Exports a signing identity to a password-protected .p12 file, as a backup.
#
#   tools/export_signing_identity.sh ~/Downloads/klik-signing-backup.p12
#
# The keychain is already the safe place for a certificate -- it is encrypted and
# unlocked by your login. A .p12 file is a *portable copy*, useful for moving to
# another Mac or restoring after wiping this one. It contains the private key, so
# it is only as safe as the password you give it and wherever you put it.
#
# Restore with: tools/import_signing_identity.sh <file.p12>

set -euo pipefail

DEST="${1:-}"
if [[ -z "$DEST" ]]; then
  echo "usage: $0 <destination.p12> [identity name]" >&2
  echo >&2
  echo "Available identities:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

NAME="${2:-}"
if [[ -z "$NAME" ]]; then
  NAME=$(security find-identity -v -p codesigning \
         | grep -oE '"[^"]+"' | head -1 | tr -d '"')
fi

if [[ -z "$NAME" ]]; then
  echo "No code signing identity found to export." >&2
  exit 1
fi

echo "Exporting: $NAME"
echo "       to: $DEST"
echo
echo "You will be asked twice for a password:"
echo "  1. a NEW password to protect the backup file (remember it, there is no recovery)"
echo "  2. your Mac login password, so the keychain will release the private key"
echo

security export -t identities -f pkcs12 -o "$DEST"

chmod 600 "$DEST"
echo
echo "Done. $DEST is protected by the password you chose."
echo "Anyone with both the file and that password can sign software as you."
echo "Keep it somewhere you control, such as an encrypted disk or a password manager."
