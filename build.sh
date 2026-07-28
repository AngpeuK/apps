#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUTPUT="$ROOT/dist/apps.app"

mkdir -p "$OUTPUT/Contents/MacOS"
mkdir -p "$OUTPUT/Contents/Resources"
cp "$ROOT/Info.plist" "$OUTPUT/Contents/Info.plist"
cp "$ROOT/assets/apps.icns" "$OUTPUT/Contents/Resources/apps.icns"
xcrun clang \
  -fobjc-arc \
  -O2 \
  -framework AppKit \
  -framework ApplicationServices \
  -framework ServiceManagement \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework CoreMedia \
  -framework CoreVideo \
  "$ROOT/main.m" \
  -o "$OUTPUT/Contents/MacOS/apps"
codesign --force --deep --sign - \
  --requirements '=designated => identifier "ee.antero.apps"' \
  "$OUTPUT"
echo "$OUTPUT"
