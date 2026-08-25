#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/AI Gate.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
MACOS="$CONTENTS/MacOS"

rm -rf "$BUILD"
mkdir -p "$RES" "$MACOS"

echo "Building AI Gate.app..."
xcrun swiftc -parse-as-library "$ROOT/AIStackApp.swift" \
  -o "$MACOS/AIStackApp" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/AI-Stack.command" "$RES/AI-Stack.command"
chmod +x "$RES/AI-Stack.command"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo ""
echo "Built: $APP"
echo "Run: open \"$APP\""
