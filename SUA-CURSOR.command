#!/bin/zsh
# Sửa cấu hình Cursor BYOK sau khi AI Gate ghi nhầm các key trong state.vscdb.
# Chạy file này (double-click) — script sẽ tự Quit Cursor, sửa DB, Apply lại, mở Cursor.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPAIR="$ROOT/Assets/cursor_repair_after_quit.py"
APPLY="$ROOT/Assets/cursor_apply_config.py"
[[ -f "$REPAIR" ]] || REPAIR="$ROOT/build/AI Gate.app/Contents/Resources/cursor_repair_after_quit.py"
[[ -f "$APPLY" ]] || APPLY="$ROOT/build/AI Gate.app/Contents/Resources/cursor_apply_config.py"

echo "=== AI Gate: Sửa Cursor BYOK ==="
echo "1. Đang thoát Cursor…"
osascript -e 'tell application "Cursor" to quit' 2>/dev/null || true

echo "2. Chờ Cursor ghi xong database…"
/usr/bin/python3 "$REPAIR" --model my-combo --timeout 120

echo "3. Apply Base URL + API key (Cursor đã tắt)…"
/usr/bin/python3 "$APPLY" --model my-combo --no-relaunch

echo "4. Mở lại Cursor…"
open -a Cursor

echo ""
echo "XONG. Trong Cursor: chọn model my-combo, Agent mode, chat hello."
echo "Log: ~/ai-stack/logs/cursor-repair.log"
read -r "?Nhấn Enter để đóng…" _
