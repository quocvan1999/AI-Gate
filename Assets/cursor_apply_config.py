#!/usr/bin/env python3
"""Apply AI Gate Cursor Bridge settings into Cursor's state.vscdb."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

APPLICATION_USER_KEY = (
    "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl"
    ".persistentStorage.applicationUser"
)
OPENAI_KEY_PLAIN = "cursorAuth/openAIKey"
OPENAI_KEY_SECRET = "secret://cursorAuth/openAIKey"

CURSOR_MODES = (
    "composer",
    "cmd-k",
    "background-composer",
    "composer-ensemble",
    "plan-execution",
    "spec",
    "deep-search",
    "quick-agent",
)


def out(ok: bool, **extra: Any) -> int:
    payload = {"ok": ok, **extra}
    print(json.dumps(payload, ensure_ascii=False))
    return 0 if ok else 1


def home() -> Path:
    return Path.home()


def bridge_status_path() -> Path:
    return home() / "ai-stack" / "cursor-bridge" / "status.json"


def cursor_db_path() -> Path:
    return (
        home()
        / "Library"
        / "Application Support"
        / "Cursor"
        / "User"
        / "globalStorage"
        / "state.vscdb"
    )


def read_bridge_base_url(explicit: str) -> str:
    if explicit:
        return explicit.rstrip("/")
    path = bridge_status_path()
    if not path.exists():
        return ""
    try:
        data = json.loads(path.read_text())
        return str(data.get("baseUrl") or "").rstrip("/")
    except Exception:
        return ""


def read_nine_router_key() -> str:
    db = home() / ".9router" / "db" / "data.sqlite"
    if not db.exists():
        return ""
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        row = con.execute(
            "SELECT key FROM apiKeys WHERE isActive=1 ORDER BY createdAt ASC LIMIT 1"
        ).fetchone()
        con.close()
        return (row[0] if row else "") or ""
    except Exception:
        return ""


def cursor_running() -> bool:
    try:
        r = subprocess.run(
            ["pgrep", "-x", "Cursor"],
            capture_output=True,
            text=True,
        )
        return r.returncode == 0
    except Exception:
        return False


def quit_cursor(timeout_s: float = 12.0) -> bool:
    if not cursor_running():
        return True
    subprocess.run(
        ["osascript", "-e", 'tell application "Cursor" to quit'],
        capture_output=True,
        text=True,
    )
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if not cursor_running():
            # give DB a moment to flush
            time.sleep(0.6)
            return True
        time.sleep(0.25)
    return not cursor_running()


def relaunch_cursor() -> None:
    app = Path("/Applications/Cursor.app")
    if app.exists():
        subprocess.Popen(["open", "-a", "Cursor"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def encrypt_electron_secret(plaintext: str) -> Optional[str]:
    """Chromium/Electron safeStorage on macOS (v10 + AES-128-CBC via openssl)."""
    try:
        from hashlib import pbkdf2_hmac
        import binascii
    except Exception:
        return None
    password = _keychain_password()
    if not password:
        return None
    key = pbkdf2_hmac("sha1", password.encode("utf-8"), b"saltysalt", 1003, dklen=16)
    iv = b" " * 16
    data = plaintext.encode("utf-8")
    pad_len = 16 - (len(data) % 16)
    data = data + bytes([pad_len] * pad_len)
    proc = subprocess.run(
        [
            "openssl",
            "enc",
            "-aes-128-cbc",
            "-K",
            binascii.hexlify(key).decode(),
            "-iv",
            binascii.hexlify(iv).decode(),
            "-nosalt",
        ],
        input=data,
        capture_output=True,
    )
    if proc.returncode != 0:
        return None
    blob = b"v10" + proc.stdout
    return json.dumps({"type": "Buffer", "data": list(blob)}, separators=(",", ":"))


def _keychain_password() -> str:
    for acct in ("Cursor", "Cursor Key"):
        try:
            r = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-w",
                    "-s",
                    "Cursor Safe Storage",
                    "-a",
                    acct,
                ],
                capture_output=True,
                text=True,
            )
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except Exception:
            continue
    return ""


def ensure_model_in_blob(blob: dict, model: str, base_url: str) -> dict:
    blob = dict(blob)
    blob["openAIBaseUrl"] = base_url
    blob["useOpenAIKey"] = True

    ai = dict(blob.get("aiSettings") or {})
    uam = [str(x) for x in (ai.get("userAddedModels") or [])]
    moe = [str(x) for x in (ai.get("modelOverrideEnabled") or [])]
    if model not in uam:
        uam.append(model)
    if model not in moe:
        moe.append(model)
    # remove from disabled if present
    mod = [str(x) for x in (ai.get("modelOverrideDisabled") or [])]
    mod = [x for x in mod if x != model]

    cfg = dict(ai.get("modelConfig") or {})
    for mode in CURSOR_MODES:
        entry = dict(cfg.get(mode) or {})
        # Keep background-composer on default unless already custom
        if mode == "background-composer" and entry.get("modelName") in (None, "", "default"):
            cfg[mode] = entry or {
                "modelName": "default",
                "maxMode": True,
                "selectedModels": [{"modelId": "default", "parameters": []}],
            }
            continue
        if mode in ("composer", "plan-execution", "quick-agent", "deep-search", "spec"):
            entry["modelName"] = model
            entry["selectedModels"] = [{"modelId": model, "parameters": []}]
            if "maxMode" not in entry:
                entry["maxMode"] = False
            cfg[mode] = entry

    ai["userAddedModels"] = uam
    ai["modelOverrideEnabled"] = moe
    ai["modelOverrideDisabled"] = mod
    ai["modelConfig"] = cfg
    blob["aiSettings"] = ai
    return blob


def apply(base_url: str, model: str, api_key: str, relaunch: bool) -> int:
    db_path = cursor_db_path()
    if not db_path.exists():
        return out(
            False,
            message="Chưa có Cursor state.vscdb — mở Cursor một lần rồi bấm Apply lại.",
            baseUrl=base_url,
            model=model,
        )
    if not base_url:
        return out(False, message="Chưa có Base URL Funnel. Bật Cursor Bridge trước.", model=model)
    if not api_key:
        return out(
            False,
            message="Không đọc được API key 9Router (~/.9router).",
            baseUrl=base_url,
            model=model,
        )

    was_running = cursor_running()
    if was_running and not quit_cursor():
        return out(
            False,
            message="Không tắt được Cursor để ghi cấu hình. Quit Cursor rồi bấm Apply lại.",
            baseUrl=base_url,
            model=model,
        )

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = db_path.with_name(f"state.vscdb.aigate-bak-{ts}")
    try:
        shutil.copy2(db_path, backup)
    except Exception as e:
        return out(False, message=f"Không backup state.vscdb: {e}")

    encrypted = encrypt_electron_secret(api_key)
    try:
        con = sqlite3.connect(str(db_path))
        row = con.execute(
            "SELECT value FROM ItemTable WHERE key=?", (APPLICATION_USER_KEY,)
        ).fetchone()
        if not row or not row[0]:
            con.close()
            return out(
                False,
                message="Cursor chưa có applicationUser — mở Cursor Settings một lần rồi Apply lại.",
                baseUrl=base_url,
                model=model,
            )
        blob = json.loads(row[0])
        blob = ensure_model_in_blob(blob, model, base_url)
        blob_raw = json.dumps(blob, ensure_ascii=False, separators=(",", ":"))

        con.execute(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
            (APPLICATION_USER_KEY, blob_raw),
        )
        con.execute(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
            (OPENAI_KEY_PLAIN, api_key),
        )
        if encrypted:
            con.execute(
                "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
                (OPENAI_KEY_SECRET, encrypted),
            )
        else:
            # Empty encrypted cell so legacy plaintext may be used on older builds;
            # modern Cursor needs encryption — warn caller.
            empty = json.dumps({"type": "Buffer", "data": []}, separators=(",", ":"))
            con.execute(
                "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
                (OPENAI_KEY_SECRET, empty),
            )
        con.commit()
        con.close()
    except Exception as e:
        return out(False, message=f"Ghi state.vscdb thất bại: {e}", baseUrl=base_url, model=model)

    restarted = False
    if relaunch and (was_running or True):
        relaunch_cursor()
        restarted = True

    msg = "Đã ghi Base URL + model + API key vào Cursor."
    if not encrypted:
        msg += " (Keychain encrypt không sẵn sàng — nếu Cursor không nhận key, mở Settings → Models dán key một lần.)"
    return out(
        True,
        message=msg,
        baseUrl=base_url,
        model=model,
        cursorRestarted=restarted,
        backup=str(backup),
        keyEncrypted=bool(encrypted),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply AI Gate settings into Cursor")
    parser.add_argument("--base-url", default="")
    parser.add_argument("--model", default="my-combo")
    parser.add_argument("--no-relaunch", action="store_true")
    args = parser.parse_args()
    base = read_bridge_base_url(args.base_url)
    key = read_nine_router_key()
    return apply(base, args.model.strip() or "my-combo", key, relaunch=not args.no_relaunch)


if __name__ == "__main__":
    sys.exit(main())
