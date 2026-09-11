#!/bin/bash
# Builds MacPulse.app from the SwiftPM target and assembles a signed bundle.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/MacPulse.app"
CONFIG="${CONFIG:-release}"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MacPulse"

echo "==> Rendering icon"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift Tools/make-icon.swift "$WORK/icon.png" >/dev/null
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
# Retina variants are the next size up, named for the point size they serve.
for pair in "16 32" "32 64" "128 256" "256 512" "512 1024"; do
  set -- $pair
  cp "$ICONSET/icon_${2}x${2}.png" "$ICONSET/icon_${1}x${1}@2x.png"
done
rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacPulse"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --options runtime --timestamp=none "$APP" 2>/dev/null \
  || codesign --force --deep --sign - "$APP"

# The finder needs a nudge to pick up a freshly written bundle's icon.
touch "$APP"

echo
echo "Built: $APP"
echo "Run:   open \"$APP\""
