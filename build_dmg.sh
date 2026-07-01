#!/bin/bash
# Build Coast.app and package it into Coast.dmg (drag-to-install), with the
# motion-cursor icon applied to the app, the dmg volume, and the dmg file.
# Usage: ./build_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Coast"
BUNDLE_ID="com.eastwoodseth.coast"
VERSION="1.0.0"
SIGN_IDENTITY="Coast Self-Signed"
KEYCHAIN="coast-codesign.keychain"
KC_PASS="coast"
PY=".venv/bin/python"
PYI=".venv/bin/pyinstaller"
PLISTBUDDY="/usr/libexec/PlistBuddy"
VOL="/Volumes/${APP}"

echo "==> Generating ${APP}.icns"
"$PY" make_icon.py

echo "==> Cleaning previous build"
rm -rf build dist dmg_staging "${APP}.dmg" "${APP}_rw.dmg"
[ -d "$VOL" ] && hdiutil detach "$VOL" >/dev/null 2>&1 || true

echo "==> Building ${APP}.app with PyInstaller"
"$PYI" --noconfirm --clean --windowed \
  --name "$APP" \
  --icon "${APP}.icns" \
  --osx-bundle-identifier "$BUNDLE_ID" \
  --hidden-import objc \
  --hidden-import PyObjCTools.AppHelper \
  main.py

PLIST="dist/${APP}.app/Contents/Info.plist"

echo "==> Patching Info.plist (menu-bar-only app + version)"
"$PLISTBUDDY" -c "Add :LSUIElement bool true" "$PLIST" 2>/dev/null \
  || "$PLISTBUDDY" -c "Set :LSUIElement true" "$PLIST"
"$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST" 2>/dev/null \
  || "$PLISTBUDDY" -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST"
"$PLISTBUDDY" -c "Set :CFBundleVersion $VERSION" "$PLIST" 2>/dev/null \
  || "$PLISTBUDDY" -c "Add :CFBundleVersion string $VERSION" "$PLIST"
"$PLISTBUDDY" -c "Add :LSMinimumSystemVersion string 11.0" "$PLIST" 2>/dev/null || true

echo "==> Code signing (stable self-signed identity, so permissions persist)"
./make_cert.sh || true   # idempotent: ensures the identity exists
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN" 2>/dev/null || true
  codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN" "dist/${APP}.app"
  echo "   signed with '$SIGN_IDENTITY'"
else
  echo "   WARNING: stable identity unavailable; falling back to ad-hoc (permissions won't persist)"
  codesign --force --deep --sign - "dist/${APP}.app"
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
"$PY" set_icon.py "${APP}.icns" "$VOL"
hdiutil detach "$VOL" >/dev/null 2>&1 || hdiutil detach "$VOL" -force >/dev/null

echo "==> Compressing to ${APP}.dmg"
hdiutil convert "${APP}_rw.dmg" -format UDZO -o "${APP}.dmg" -ov >/dev/null
rm -f "${APP}_rw.dmg"

echo "==> Applying icon to the ${APP}.dmg file"
"$PY" set_icon.py "${APP}.icns" "${APP}.dmg"

echo "==> Cleaning icon intermediates"
rm -rf "${APP}.iconset" "${APP}_master.png" dmg_staging

echo "==> Done: $(pwd)/${APP}.dmg"
