#!/bin/bash
# Build ClaudeDeck.app — a menu bar overview of running Claude Code sessions.
#
# Usage: ./build.sh [--universal]
#   --universal  build for both arm64 and x86_64 (used by CI releases)
set -euo pipefail
cd "$(dirname "$0")"

APP=ClaudeDeck
BUNDLE="$APP.app"
VERSION="$(tr -d '[:space:]' < VERSION)"

ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then
    ARCH_FLAGS=(-arch arm64 -arch x86_64)
fi

clang -fobjc-arc -O2 -Wall -Werror \
    "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" \
    -DCLAUDEDECK_VERSION="\"$VERSION\"" \
    -framework Cocoa -framework WebKit \
    Sources/ClaudeDeckCore.m Sources/CDPtySession.m Sources/CDTerminalWindowController.m Sources/main.m \
    -o "$APP"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp -R Resources/ "$BUNDLE/Contents/Resources/"
cp Info.plist "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$BUNDLE/Contents/Info.plist"
mv "$APP" "$BUNDLE/Contents/MacOS/$APP"
codesign --force --sign - "$BUNDLE"

echo "Built $BUNDLE (v$VERSION)"
echo "Run:  open $BUNDLE"
