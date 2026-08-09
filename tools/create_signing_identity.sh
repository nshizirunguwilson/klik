#!/usr/bin/env bash
# Creates a self-signed certificate for signing Klik locally.
#
# Why this exists: an ad-hoc signature changes every time the app is rebuilt, and
# macOS treats each new signature as a different app that has to earn its
# Accessibility permission again. Signing with a certificate that stays the same
# means the permission is granted once and then sticks.
#
# Run once. It may ask for your login password.

set -euo pipefail

NAME="Klik Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Signing identity \"$NAME\" already exists. Nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3
[ dn ]
CN = Klik Local Signing
O  = Klik
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> Generating certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null

# -legacy matters: OpenSSL 3 defaults to AES-256/SHA-256 for the archive, which
# macOS's keychain importer cannot read. It rejects the file as a bad password.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:klik -name "$NAME" 2>/dev/null

echo "==> Importing into your login keychain"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P klik -A -T /usr/bin/codesign

echo
echo "Done. \"$NAME\" is now available for signing."
echo "build.sh will pick it up automatically from here on."
