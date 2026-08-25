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
  -framework Foundation -O

echo "🔨 Compiling for Intel Macs (x86_64)..."
xcrun swiftc -target x86_64-apple-macos14.0 -parse-as-library "$ROOT/AIStackApp.swift" \
  -o "$TMP_DIR/AIStackApp_x86_64" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation -O

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

echo "🔏 Code signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "📀 Creating DMG Installer..."
DMG_NAME="AI-Gate-Installer.dmg"
DMG_TEMP="$TMP_DIR/dmg_content"
mkdir -p "$DMG_TEMP"
cp -R "$APP" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

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
