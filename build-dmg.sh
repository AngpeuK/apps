#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUTPUT="$ROOT/../../outputs/DMG"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
STAGING="$OUTPUT/.staging"

frameworks=(
  -framework AppKit
  -framework ApplicationServices
  -framework ServiceManagement
  -framework ScreenCaptureKit
  -framework AVFoundation
  -framework AudioToolbox
  -framework CoreMedia
  -framework CoreVideo
)

build_app() {
  local label="$1"
  shift
  local app="$STAGING/$label/apps.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$ROOT/Info.plist" "$app/Contents/Info.plist"
  cp "$ROOT/assets/apps.icns" "$app/Contents/Resources/apps.icns"
  xcrun clang -fobjc-arc -O2 "$@" "${frameworks[@]}" "$ROOT/main.m" -o "$app/Contents/MacOS/apps"
  codesign --force --deep --sign - \
    --requirements '=designated => identifier "ee.antero.apps"' "$app"
}

make_dmg() {
  local label="$1"
  local filename="$2"
  local source="$STAGING/$label/disk"
  mkdir -p "$source"
  cp -R "$STAGING/$label/apps.app" "$source/apps.app"
  ln -s /Applications "$source/Applications"
  mkdir -p "$source/Скрипты"
  cp "$ROOT/scripts/show-hidden-files.command" "$source/Скрипты/Показать скрытые файлы.command"
  cp "$ROOT/scripts/hide-hidden-files.command" "$source/Скрипты/Скрыть скрытые файлы.command"
  chmod +x "$source/Скрипты/"*.command
  hdiutil create -quiet -volname "apps $VERSION" -srcfolder "$source" \
    -ov -format UDZO "$OUTPUT/$filename"
}

mkdir -p "$OUTPUT"
rm -rf "$STAGING"
mkdir -p "$STAGING"

build_app intel -arch x86_64
build_app silicon -arch arm64

mkdir -p "$STAGING/universal/apps.app/Contents/MacOS" "$STAGING/universal/apps.app/Contents/Resources"
cp "$ROOT/Info.plist" "$STAGING/universal/apps.app/Contents/Info.plist"
cp "$ROOT/assets/apps.icns" "$STAGING/universal/apps.app/Contents/Resources/apps.icns"
lipo -create \
  "$STAGING/intel/apps.app/Contents/MacOS/apps" \
  "$STAGING/silicon/apps.app/Contents/MacOS/apps" \
  -output "$STAGING/universal/apps.app/Contents/MacOS/apps"
codesign --force --deep --sign - \
  --requirements '=designated => identifier "ee.antero.apps"' "$STAGING/universal/apps.app"

make_dmg intel "apps-$VERSION-Intel.dmg"
make_dmg silicon "apps-$VERSION-Apple-Silicon.dmg"
make_dmg universal "apps-$VERSION-Universal.dmg"

rm -rf "$STAGING"
echo "$OUTPUT"
