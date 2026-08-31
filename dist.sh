#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/AI Gate.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
MACOS="$CONTENTS/MacOS"

echo "=============================================="
echo "🚀 Building Universal macOS Application..."
echo "=============================================="

rm -rf "$BUILD" "$DIST"
mkdir -p "$RES" "$MACOS" "$DIST"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "🔨 Compiling for Apple Silicon (arm64)..."
xcrun swiftc -target arm64-apple-macos14.0 -parse-as-library "$ROOT/AIStackApp.swift" \
  -o "$TMP_DIR/AIStackApp_arm64" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework CryptoKit -O

echo "🔨 Compiling for Intel Macs (x86_64)..."
xcrun swiftc -target x86_64-apple-macos14.0 -parse-as-library "$ROOT/AIStackApp.swift" \
  -o "$TMP_DIR/AIStackApp_x86_64" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework CryptoKit -O

echo "🔗 Combining into Universal 2 Binary (lipo)..."
lipo -create "$TMP_DIR/AIStackApp_arm64" "$TMP_DIR/AIStackApp_x86_64" -output "$MACOS/AIStackApp"

# Check binary architecture
lipo -info "$MACOS/AIStackApp"

echo "📦 Bundling Resources..."
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/AI-Stack.command" ]]; then
  cp "$ROOT/AI-Stack.command" "$RES/AI-Stack.command"
  chmod +x "$RES/AI-Stack.command"
fi
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

echo "🔏 Code signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "📀 Creating DMG Installer..."
DMG_NAME="AI-Gate-Installer.dmg"
DMG_TEMP="$TMP_DIR/dmg_content"
mkdir -p "$DMG_TEMP"
cp -R "$APP" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"
cp "$ROOT/Install-From-DMG.command" "$DMG_TEMP/Cài đặt AI Gate.command"
chmod +x "$DMG_TEMP/Cài đặt AI Gate.command"

hdiutil create -volname "AI Gate" -srcfolder "$DMG_TEMP" -ov -format UDZO "$DIST/$DMG_NAME" >/dev/null

echo "🗜️  Creating ZIP Archive..."
cd "$BUILD" && zip -r -y "$DIST/AI-Gate-macOS-Universal.zip" "AI Gate.app" >/dev/null

echo ""
echo "=============================================="
echo "✅ Build & Package Complete!"
echo "=============================================="
echo "Output files ready for distribution in 'dist/':"
echo "  1. DMG Installer: $DIST/$DMG_NAME"
echo "  2. Zip Package:   $DIST/AI-Gate-macOS-Universal.zip"
echo ""
