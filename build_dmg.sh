#!/bin/bash
# Build Coast.app (Swift, universal: Apple Silicon + Intel) and package it into Coast.dmg
# (drag-to-install), with the motion-cursor icon applied to the app, the dmg volume, and the dmg file.
# Needs Xcode or the Command Line Tools (Swift 5.9+).
# Usage: ./build_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Coast"
BUNDLE_ID="com.eastwoodseth.coast"
VERSION="$(tr -d '[:space:]' < VERSION)"   # single source of truth for the menu header and Info.plist
[ -n "$VERSION" ] || { echo "ERROR: VERSION is empty"; exit 1; }
SIGN_IDENTITY="Coast Self-Signed"
KEYCHAIN="coast-codesign.keychain"
KC_PASS="coast"
VOL="/Volumes/${APP}"
TOOLS=".build/tools"

echo "==> Cleaning previous build"
rm -rf dist dmg_staging "${APP}.dmg" "${APP}_rw.dmg"
[ -d "$VOL" ] && hdiutil detach "$VOL" >/dev/null 2>&1 || true

echo "==> Building ${APP} ${VERSION}"
swift build -c release --triple arm64-apple-macosx11.0 --product "$APP"
BINS=("$(swift build -c release --triple arm64-apple-macosx11.0 --show-bin-path)/$APP")
if swift build -c release --triple x86_64-apple-macosx11.0 --product "$APP"; then
  BINS+=("$(swift build -c release --triple x86_64-apple-macosx11.0 --show-bin-path)/$APP")
else
  echo "   WARNING: Intel build failed; packaging Apple Silicon only"
fi

echo "==> Generating ${APP}.icns"
mkdir -p "$TOOLS"
xcrun swiftc -O Tools/make_icon.swift -o "$TOOLS/make_icon"
xcrun swiftc -O Tools/set_icon.swift -o "$TOOLS/set_icon"
"$TOOLS/make_icon" "$(pwd)"

echo "==> Assembling ${APP}.app"
CONTENTS="dist/${APP}.app/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
lipo -create "${BINS[@]}" -output "$CONTENTS/MacOS/$APP"
cp "${APP}.icns" "$CONTENTS/Resources/${APP}.icns"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${APP}</string>
  <key>CFBundleDisplayName</key><string>${APP}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP}</string>
  <key>CFBundleIconFile</key><string>${APP}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "   $(lipo -archs "$CONTENTS/MacOS/$APP")"

echo "==> Code signing (stable self-signed identity, so permissions persist)"
./make_cert.sh || true   # idempotent: ensures the identity exists
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN" 2>/dev/null || true
  codesign --force --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN" "dist/${APP}.app"
  echo "   signed with '$SIGN_IDENTITY'"
else
  echo "   WARNING: stable identity unavailable; falling back to ad-hoc (permissions won't persist)"
  codesign --force --sign - "dist/${APP}.app"
fi

echo "==> Staging dmg contents"
mkdir -p dmg_staging
cp -R "dist/${APP}.app" dmg_staging/
ln -s /Applications dmg_staging/Applications

echo "==> Creating read-write dmg and applying the volume icon"
SIZE_MB=$(( $(du -sm dmg_staging | cut -f1) + 20 ))
hdiutil create -volname "$APP" -srcfolder dmg_staging -fs HFS+ \
  -format UDRW -size "${SIZE_MB}m" -ov "${APP}_rw.dmg" >/dev/null
hdiutil attach "${APP}_rw.dmg" -mountpoint "$VOL" -nobrowse >/dev/null
"$TOOLS/set_icon" "${APP}.icns" "$VOL"
hdiutil detach "$VOL" >/dev/null 2>&1 || hdiutil detach "$VOL" -force >/dev/null

echo "==> Compressing to ${APP}.dmg"
hdiutil convert "${APP}_rw.dmg" -format UDZO -o "${APP}.dmg" -ov >/dev/null
rm -f "${APP}_rw.dmg"

echo "==> Applying icon to the ${APP}.dmg file"
"$TOOLS/set_icon" "${APP}.icns" "${APP}.dmg"

rm -rf dmg_staging
echo "==> Done: $(pwd)/${APP}.dmg"
