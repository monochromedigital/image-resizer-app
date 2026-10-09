#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
# Kept in step with Scripts/check.sh — see the note there.
if [[ -n "${IMAGE_RESIZER_SDK:-}" ]]; then
  SDK="$IMAGE_RESIZER_SDK"
else
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
SCRATCH="$ROOT/.build-release"
MODULE_CACHE="$ROOT/.build-module-cache"
DIST="$ROOT/dist"
APP="$DIST/Image Resizer.app"
DMG="$DIST/Image Resizer.dmg"
ARCHITECTURES=(arm64 x86_64)
SPARKLE_FRAMEWORK="$SCRATCH/arm64-apple-macosx/release/Sparkle.framework"
SPARKLE_LICENSE="$SCRATCH/artifacts/sparkle/Sparkle/LICENSE"

mkdir -p "$DIST" "$MODULE_CACHE"
# One build per architecture, joined with lipo, rather than `swift build --arch a --arch b`:
# that routes through a different build system with a different output layout.
SLICES=()
for ARCH in $ARCHITECTURES; do
  SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift build \
    --configuration release \
    --disable-sandbox \
    --scratch-path "$SCRATCH" \
    --triple "$ARCH-apple-macosx14.0"
  SLICES+=("$SCRATCH/$ARCH-apple-macosx/release/ImageResizer")
done
lipo -create $SLICES -output "$SCRATCH/ImageResizer-universal"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
install -m 755 "$SCRATCH/ImageResizer-universal" "$APP/Contents/MacOS/ImageResizer"
install -m 644 "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
install -m 644 "$ROOT/Resources/AppIcon/ImageResizer.icns" "$APP/Contents/Resources/ImageResizer.icns"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { print -u2 -- "Missing Sparkle.framework: $SPARKLE_FRAMEWORK"; exit 1; }
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Resources/Licenses"
install -m 644 "$SPARKLE_LICENSE" "$APP/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
mkdir -p "$APP/Contents/Resources/WebPTools"
install -m 755 "$ROOT/Vendor/WebPTools/cwebp" "$APP/Contents/Resources/WebPTools/cwebp"
install -m 755 "$ROOT/Vendor/WebPTools/img2webp" "$APP/Contents/Resources/WebPTools/img2webp"
install -m 755 "$ROOT/Vendor/WebPTools/webpmux" "$APP/Contents/Resources/WebPTools/webpmux"
install -m 644 "$ROOT/Vendor/WebPTools/COPYING" "$APP/Contents/Resources/WebPTools/COPYING"
install -m 644 "$ROOT/Vendor/WebPTools/PATENTS" "$APP/Contents/Resources/WebPTools/PATENTS"

for BINARY in "$APP/Contents/MacOS/ImageResizer" "$APP/Contents/Frameworks/Sparkle.framework/Sparkle" "$APP/Contents/Resources/WebPTools/"{cwebp,img2webp,webpmux}; do
  for ARCH in $ARCHITECTURES; do
    lipo "$BINARY" -verify_arch "$ARCH" || { print -u2 -- "Missing $ARCH slice: $BINARY"; exit 1; }
  done
done

codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
rm -f "$DMG"
hdiutil create -volname "Image Resizer" -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "Created $DMG"
