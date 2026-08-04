#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
LOCAL_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -n "${IMAGE_RESIZER_SDK:-}" ]]; then
  SDK="$IMAGE_RESIZER_SDK"
elif [[ -d "$LOCAL_SDK" ]]; then
  SDK="$LOCAL_SDK"
else
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
MODULE_CACHE="$ROOT/.build-module-cache"
OUTPUT="$ROOT/.build-checks/ImageResizerChecks"

mkdir -p "${OUTPUT:h}" "$MODULE_CACHE"
SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swiftc \
  "$ROOT/Sources/ImageResizer/Models.swift" \
  "$ROOT/Sources/ImageResizer/WebExport.swift" \
  "$ROOT/Sources/ImageResizer/JobPlanner.swift" \
  "$ROOT/Checks/main.swift" \
  -o "$OUTPUT"
"$OUTPUT"

INTEGRATION="$ROOT/.build-checks/ImageResizerIntegrationChecks"
SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swiftc -parse-as-library \
  "$ROOT/Sources/ImageResizer/Models.swift" \
  "$ROOT/Sources/ImageResizer/WebExport.swift" \
  "$ROOT/Sources/ImageResizer/JobPlanner.swift" \
  "$ROOT/Sources/ImageResizer/ResizeEngine.swift" \
  "$ROOT/Sources/ImageResizer/WebPCodec.swift" \
  "$ROOT/Checks/Integration.swift" \
  -o "$INTEGRATION"
cd "$ROOT"
"$INTEGRATION"
