#!/bin/bash
# Ensures a stable, locally self-signed and trusted code-signing
# certificate exists in the login keychain, so build_app.sh can sign
# with a consistent identity instead of ad-hoc (`codesign --sign -`).
#
# An ad-hoc signature is derived from the binary's own content hash, so
# it's different on every rebuild. macOS ties Keychain item access grants
# (like the MQTT password KeychainStore stores) to the app's signing
# identity - with ad-hoc signing, every rebuild looks like a "new app" to
# the Keychain, so it re-prompts for access every time. Signing with a
# fixed identity instead means: grant Keychain access once, and it keeps
# working across rebuilds.
#
# A freshly self-signed certificate is untrusted by default though, and
# that turns out to matter for more than just Gatekeeper: macOS's
# Keychain ACL system won't durably remember an "Always Allow" grant for
# an app signed by an untrusted identity - it silently re-prompts for
# Keychain access on every single launch regardless of what was clicked
# last time. Marking the certificate as a trusted root (below) is what
# actually makes "Always Allow" stick across rebuilds/relaunches.
#
# This is a local-only identity for development convenience, not a
# Developer ID - it doesn't help with Gatekeeper/notarization for
# distributing the app to other machines.
set -euo pipefail

CERT_NAME="Monitor Input Switcher Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if ! security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> No local code-signing identity found, creating one..."
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" \
        -days 3650 -nodes -subj "/CN=$CERT_NAME" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "basicConstraints=critical,CA:true" \
        -addext "keyUsage=critical,digitalSignature,keyCertSign" >/dev/null 2>&1

    PASSPHRASE=$(uuidgen)
    # -legacy: OpenSSL 3.x defaults to AES-256 for the PKCS#12 container,
    # which macOS's Security framework (used by `security import` below)
    # can't parse ("MAC verification failed" even with the right
    # password) - it only understands the older RC2/3DES-based encoding
    # -legacy produces.
    openssl pkcs12 -export -legacy -out "$TMPDIR/cert.p12" -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" -passout "pass:$PASSPHRASE" >/dev/null 2>&1

    security import "$TMPDIR/cert.p12" -k "$KEYCHAIN" -P "$PASSPHRASE" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    echo "==> Created local code-signing identity: $CERT_NAME"

    rm -rf "$TMPDIR"
    trap - EXIT
fi

# find-identity's "Valid identities only" section lists only trusted
# ones, so absence from it (whether the cert is brand new above, or
# existed already but was never trusted - e.g. from before this trust
# step existed) means it still needs trusting.
if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    CERT_FILE=$(mktemp)
    trap 'rm -f "$CERT_FILE"' EXIT
    security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$CERT_FILE"
    security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$CERT_FILE"
    echo "==> Trusted local code-signing identity: $CERT_NAME"
    echo "    (macOS may ask for Keychain access one more time on the next"
    echo "     launch - after that it should stop for good.)"
    rm -f "$CERT_FILE"
    trap - EXIT
fi
