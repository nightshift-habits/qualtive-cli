#!/bin/bash
# Developer ID signs and notarizes a bare Mach-O binary in a temporary keychain.
# Bare binaries can't be stapled; Gatekeeper checks the notarization online on first run.
#
# Env: P12 (base64), P12_PASSWORD, KEYCHAIN_PASSWORD (optional), ASC_API_KEY_ID, ASC_API_ISSUER_ID,
#      ASC_API_KEY_P8 (base64), APPLE_TEAM_ID, SIGNING_IDENTIFIER (default io.qualtive.cli).
set -euo pipefail

binary="${1:?usage: macos-sign-notarize.sh <binary>}"
identifier="${SIGNING_IDENTIFIER:-io.qualtive.cli}"
work="$(mktemp -d)"
keychain="$work/signing.keychain-db"
keychain_password="${KEYCHAIN_PASSWORD:-$(uuidgen)}"

cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "$P12" | base64 --decode > "$work/cert.p12"
echo "$ASC_API_KEY_P8" | base64 --decode > "$work/AuthKey.p8"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/cert.p12" -k "$keychain" -P "$P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

identity="$(security find-identity -v -p codesigning "$keychain" | grep "Developer ID Application" | grep "($APPLE_TEAM_ID)" | head -1 | awk '{print $2}')"
if [ -z "$identity" ]; then
  echo "No Developer ID Application identity for team $APPLE_TEAM_ID in the .p12" >&2
  exit 1
fi

codesign --force --options runtime --timestamp --identifier "$identifier" --keychain "$keychain" --sign "$identity" "$binary"
codesign --verify --strict --verbose=2 "$binary"
codesign -dv --verbose=4 "$binary" 2>&1 | tee "$work/codesign.txt"
grep -q "TeamIdentifier=$APPLE_TEAM_ID" "$work/codesign.txt"
grep -q "flags=.*runtime" "$work/codesign.txt"

(cd "$(dirname "$binary")" && zip -q "$work/notarize.zip" "$(basename "$binary")")
xcrun notarytool submit "$work/notarize.zip" \
  --key "$work/AuthKey.p8" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" \
  --wait --timeout 30m

spctl -a -vvv -t install "$binary" || echo "spctl assessment is informational for bare binaries"
