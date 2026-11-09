#!/bin/bash
# Builds build/FileShift.app (release) and ad-hoc signs it.
#   UNIVERSAL=1 scripts/build-app.sh   -> arm64 + x86_64 universal binary (used for releases)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUNDLE_ID="io.github.brohan2001.FileShift"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
  ARCH_FLAGS=(--arch "$(uname -m)")
fi

echo "==> Compiling (release, ${ARCH_FLAGS[*]})…"
swift build -c release "${ARCH_FLAGS[@]}" --product FileShift
swift build -c release "${ARCH_FLAGS[@]}" --product fileshift-cli
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="$ROOT/build/FileShift.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FileShift" "$APP/Contents/MacOS/FileShift"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN/fileshift-cli" "$ROOT/build/fileshift-cli"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
echo "==> Built $APP ($(lipo -archs "$APP/Contents/MacOS/FileShift"))"
