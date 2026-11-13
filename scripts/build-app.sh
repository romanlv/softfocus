#!/bin/bash
# Builds build/Softfocus.app. Universal (arm64 + x86_64) release by default.
#   CONFIG=debug ARCHS=arm64 scripts/build-app.sh   # faster local build
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
ARCHS=${ARCHS:-"arm64 x86_64"}
ARCH_ARGS=()
for a in $ARCHS; do ARCH_ARGS+=(--arch "$a"); done

swift build -c "$CONFIG" "${ARCH_ARGS[@]}" --product Softfocus
BIN_DIR=$(swift build -c "$CONFIG" "${ARCH_ARGS[@]}" --show-bin-path)

APP=build/Softfocus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Softfocus" "$APP/Contents/MacOS/Softfocus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Softfocus.sdef "$APP/Contents/Resources/"

if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime \
  --entitlements Resources/Softfocus.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Softfocus"))"
