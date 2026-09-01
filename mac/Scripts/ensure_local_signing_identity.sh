#!/bin/bash
# Ensures a stable, locally self-signed code-signing certificate exists in
# the login keychain, so build_app.sh can sign with a consistent identity
# instead of ad-hoc (`codesign --sign -`).
#
# An ad-hoc signature is derived from the binary's own content hash, so
# it's different on every rebuild. macOS ties Keychain item access grants
# (like the MQTT password KeychainStore stores) to the app's signing
# identity - with ad-hoc signing, every rebuild looks like a "new app" to
# the Keychain, so it re-prompts for access every time. Signing with a
# fixed identity instead means: grant Keychain access once, and it keeps
# working across rebuilds.
#
# This is a local-only identity for development convenience, not a
# Developer ID - it doesn't help with Gatekeeper/notarization for
# distributing the app to other machines.
set -euo pipefail

CERT_NAME="Monitor Input Switcher Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    exit 0
fi

echo "==> No local code-signing identity found, creating one..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=$CERT_NAME" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" >/dev/null 2>&1

PASSPHRASE=$(uuidgen)
# -legacy: OpenSSL 3.x defaults to AES-256 for the PKCS#12 container, which
# macOS's Security framework (used by `security import` below) can't parse
# ("MAC verification failed" even with the right password) - it only
# understands the older RC2/3DES-based encoding -legacy produces.
openssl pkcs12 -export -legacy -out "$TMPDIR/cert.p12" -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" -passout "pass:$PASSPHRASE" >/dev/null 2>&1

security import "$TMPDIR/cert.p12" -k "$KEYCHAIN" -P "$PASSPHRASE" -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> Created local code-signing identity: $CERT_NAME"
echo "    (macOS will ask for Keychain access one more time on the next"
echo "     launch, since this identity is new - after that it should stop.)"
