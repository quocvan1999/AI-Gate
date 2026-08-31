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
  -framework Foundation \
  -framework CryptoKit

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/AI-Stack.command" "$RES/AI-Stack.command"
chmod +x "$RES/AI-Stack.command"
cp "$ROOT/Assets/AppIcon.icns" "$RES/AppIcon.icns"
cp "$ROOT/Assets/AppIcon.png" "$RES/AppIcon.png"
cp "$ROOT/Assets/NavIcon.png" "$RES/NavIcon.png"
cp "$ROOT/Assets/cursor_apply_config.py" "$RES/cursor_apply_config.py"
cp "$ROOT/Assets/cursor_repair_after_quit.py" "$RES/cursor_repair_after_quit.py"
cp "$ROOT/Assets/cursor_path_health.py" "$RES/cursor_path_health.py"
cp "$ROOT/Assets/codex_apply_config.py" "$RES/codex_apply_config.py"
cp "$ROOT/Assets/codex_test.py" "$RES/codex_test.py"
cp "$ROOT/Assets/cursor_test.py" "$RES/cursor_test.py"
cp "$ROOT/Assets/cursor_responses_shim.py" "$RES/cursor_responses_shim.py"
cp "$ROOT/Assets/backup_restore.py" "$RES/backup_restore.py"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo ""
echo "Built: $APP"
echo "Run: open \"$APP\""
