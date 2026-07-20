#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
SCRATCH="$ROOT/.build-release"
MODULE_CACHE="$ROOT/.build-module-cache"
DIST="$ROOT/dist"
APP="$DIST/Image Resizer.app"
DMG="$DIST/Image Resizer.dmg"

mkdir -p "$DIST" "$MODULE_CACHE"
SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift build \
  --configuration release \
  --disable-sandbox \
  --scratch-path "$SCRATCH"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$SCRATCH/arm64-apple-macosx/release/ImageResizer" "$APP/Contents/MacOS/ImageResizer"
install -m 644 "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
install -m 644 "$ROOT/Resources/AppIcon/ImageResizer.icns" "$APP/Contents/Resources/ImageResizer.icns"
mkdir -p "$APP/Contents/Resources/WebPTools"
install -m 755 "$ROOT/Vendor/WebPTools/cwebp" "$APP/Contents/Resources/WebPTools/cwebp"
install -m 755 "$ROOT/Vendor/WebPTools/img2webp" "$APP/Contents/Resources/WebPTools/img2webp"
install -m 755 "$ROOT/Vendor/WebPTools/webpmux" "$APP/Contents/Resources/WebPTools/webpmux"
install -m 644 "$ROOT/Vendor/WebPTools/COPYING" "$APP/Contents/Resources/WebPTools/COPYING"
install -m 644 "$ROOT/Vendor/WebPTools/PATENTS" "$APP/Contents/Resources/WebPTools/PATENTS"

codesign --force --deep --sign - "$APP"
rm -f "$DMG"
hdiutil create -volname "Image Resizer" -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "Created $DMG"
