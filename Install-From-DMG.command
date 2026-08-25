#!/bin/zsh
# One-click installer for the AI Gate DMG:
# copy app → eject disk image → delete the .dmg → launch app.
set -euo pipefail

APP_NAME="AI Gate.app"
TARGET="/Applications/${APP_NAME}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="${SCRIPT_DIR}/${APP_NAME}"

if [[ ! -d "$SOURCE_APP" ]]; then
  osascript -e 'display alert "Không tìm thấy AI Gate.app" message "Hãy mở file AI-Gate-Installer.dmg rồi chạy lại «Cài đặt AI Gate»." as critical'
  exit 1
fi

osascript -e 'display notification "Đang cài AI Gate vào Applications…" with title "AI Gate"'

rm -rf "$TARGET"
ditto "$SOURCE_APP" "$TARGET"
xattr -cr "$TARGET" 2>/dev/null || true

DEVICE=""
IMAGE_PATH=""
VOLUME=""

if [[ "$SCRIPT_DIR" == /Volumes/* ]]; then
  VOLUME="$(df "$SCRIPT_DIR" | awk 'NR==2 {print $NF}')"
  DEVICE="$(df "$SCRIPT_DIR" | awk 'NR==2 {print $1}')"
  current_image=""
  while IFS= read -r line; do
    if [[ "$line" == image-path* ]]; then
      current_image="${line#*: }"
      current_image="${current_image#"${current_image%%[![:space:]]*}"}"
    fi
    if [[ -n "$DEVICE" && "$line" == *"$DEVICE"* ]]; then
      IMAGE_PATH="$current_image"
    fi
  done < <(hdiutil info)
fi

CLEANUP="$(mktemp /tmp/ai-gate-cleanup.XXXXXX.sh)"
cat > "$CLEANUP" <<'EOF'
#!/bin/zsh
DEVICE="$1"
VOLUME="$2"
IMAGE_PATH="$3"
sleep 2
if [[ -n "$VOLUME" && -d "$VOLUME" ]]; then
  hdiutil detach "$VOLUME" -force >/dev/null 2>&1 || true
fi
if [[ -n "$DEVICE" ]]; then
  hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
fi
sleep 1
if [[ -n "$IMAGE_PATH" && "$IMAGE_PATH" == *.dmg && -f "$IMAGE_PATH" ]]; then
  rm -f "$IMAGE_PATH"
fi
open "/Applications/AI Gate.app"
rm -f "$0"
EOF
chmod +x "$CLEANUP"

cd /
nohup "$CLEANUP" "$DEVICE" "$VOLUME" "$IMAGE_PATH" >/dev/null 2>&1 &

osascript -e 'display notification "Đã cài xong. Đĩa ảo sẽ được tháo và file .dmg sẽ bị xoá." with title "AI Gate"'
exit 0
