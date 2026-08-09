#!/usr/bin/env bash
# Restores a signing identity from a .p12 backup into the login keychain.
#
#   tools/import_signing_identity.sh ~/Downloads/klik-signing-backup.p12

set -euo pipefail

SOURCE="${1:-}"
if [[ -z "$SOURCE" || ! -f "$SOURCE" ]]; then
  echo "usage: $0 <backup.p12>" >&2
  exit 1
fi

echo "Importing $SOURCE into your login keychain."
echo "You will be asked for the password that protects the file."
security import "$SOURCE" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -T /usr/bin/codesign

echo
echo "Done. Identities now available:"
security find-identity -v -p codesigning
