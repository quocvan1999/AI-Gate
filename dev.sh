#!/bin/zsh
# ============================================================
# AI Gate - Hot Reload / Watch & Rebuild Script
# ============================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"
SWIFT_FILE="$ROOT/AIStackApp.swift"
APP="$ROOT/build/AI Gate.app"

echo "🚀 AI Gate Watcher Started..."
echo "👀 Watching file: AIStackApp.swift"
echo "Press Ctrl+C to stop watcher."
echo "------------------------------------------------------------"

rebuild_and_launch() {
    echo "\n🔄 Change detected at $(date +'%H:%M:%S')! Rebuilding..."
    
    # Close running instance of AIStackApp to reload fresh build
    pkill -f "AIStackApp" 2>/dev/null || true
    sleep 0.3

    if "$ROOT/build.sh"; then
        echo "✅ Build succeeded! Opening AI Gate..."
        open "$APP"
    else
        echo "❌ Build failed! Please fix errors above and save again."
    fi
}

# Perform initial build & launch
rebuild_and_launch

LAST_MD5=$(md5 -q "$SWIFT_FILE" 2>/dev/null)

while true; do
    CURRENT_MD5=$(md5 -q "$SWIFT_FILE" 2>/dev/null)
    if [[ "$CURRENT_MD5" != "$LAST_MD5" ]]; then
        LAST_MD5="$CURRENT_MD5"
        rebuild_and_launch
    fi
    sleep 1
done
