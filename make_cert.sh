#!/bin/bash
# Create a STABLE self-signed code-signing identity for Coast, so macOS keeps
# Accessibility / Input Monitoring grants across rebuilds (instead of treating
# every ad-hoc build as a brand-new app). Idempotent: run once; re-runs are no-ops.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Coast Self-Signed"
KEYCHAIN="coast-codesign.keychain"
KC_PASS="coast"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "Identity '$IDENTITY' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating self-signed code-signing certificate"
cat > "$TMP/cfg" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Coast Self-Signed
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$IDENTITY" -out "$TMP/coast.p12" -passout pass:coast 2>/dev/null

echo "==> Importing into a dedicated keychain (password: $KC_PASS)"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # disable auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$TMP/coast.p12" -k "$KEYCHAIN" -P coast -T /usr/bin/codesign
# Let codesign use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1
# Add to the search list (prepend) so codesign/find-identity can see it.
EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $EXISTING

echo "==> Done."
security find-identity -p codesigning | grep "$IDENTITY" || {
  echo "WARNING: identity not listed by find-identity"; exit 1; }
