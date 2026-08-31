#!/usr/bin/env python3
"""Repair Cursor BYOK config once Cursor has exited.

Cursor keeps applicationUser in memory and flushes it on exit, so patching
state.vscdb while it runs is silently reverted. This waits for the process to
disappear, then removes the keys that break model routing and re-applies the
Base URL / model / key.
"""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

APPLICATION_USER_KEY = (
    "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl"
    ".persistentStorage.applicationUser"
)
CURSOR_PROC = "/Applications/Cursor.app/Contents/MacOS/Cursor"
# Written by an earlier AI Gate version; Cursor rejects the blob and falls back
# to its own agent backend when these are present.
BAD_KEYS = ("availableAPIKeyModels", "featureModelConfigs")
COMBO_MODES = ("composer", "plan-execution", "quick-agent", "deep-search", "spec")

LOG = Path.home() / "ai-stack" / "logs" / "cursor-repair.log"


def log(msg: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def cursor_running() -> bool:
    try:
        r = subprocess.run(["ps", "-A", "-o", "comm="], capture_output=True, text=True)
        if r.returncode == 0:
            return any(l.strip() == CURSOR_PROC for l in r.stdout.splitlines())
    except Exception:
        pass
    return False


def db_path() -> Path:
    return (
        Path.home()
        / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    )


def bridge_base_url() -> str:
    path = Path.home() / "ai-stack" / "cursor-bridge" / "status.json"
    try:
        return str(json.loads(path.read_text()).get("baseUrl") or "").rstrip("/")
    except Exception:
        return ""


def patch(model: str) -> dict:
    path = db_path()
    con = sqlite3.connect(str(path))
    row = con.execute(
        "SELECT value FROM ItemTable WHERE key=?", (APPLICATION_USER_KEY,)
    ).fetchone()
    if not row or not row[0]:
        con.close()
        return {"ok": False, "message": "Không đọc được applicationUser"}

    blob = json.loads(row[0])
    removed = [k for k in BAD_KEYS if k in blob]
    for k in BAD_KEYS:
        blob.pop(k, None)

    adm = blob.get("availableDefaultModels2")
    fake = 0
    if isinstance(adm, list):
        keep = []
        for item in adm:
            if (
                isinstance(item, dict)
                and item.get("isUserAdded")
                and item.get("name") == model
            ):
                fake += 1
                continue
            keep.append(item)
        blob["availableDefaultModels2"] = keep

    base = bridge_base_url()
    if base:
        blob["openAIBaseUrl"] = base
    blob["useOpenAIKey"] = True

    ai = dict(blob.get("aiSettings") or {})
    uam = [str(x) for x in (ai.get("userAddedModels") or [])]
    if model not in uam:
        uam.append(model)
    moe = [str(x) for x in (ai.get("modelOverrideEnabled") or [])]
    if model not in moe:
        moe.append(model)
    ai["userAddedModels"] = uam
    ai["modelOverrideEnabled"] = moe
    ai["modelOverrideDisabled"] = [
        x for x in (ai.get("modelOverrideDisabled") or []) if x != model
    ]

    cfg = dict(ai.get("modelConfig") or {})
    for mode in ("cmd-k", "background-composer", "composer-ensemble"):
        entry = dict(cfg.get(mode) or {})
        if entry.get("modelName") == model:
            cfg[mode] = {
                "modelName": "default",
                "maxMode": mode == "background-composer",
                "selectedModels": [{"modelId": "default", "parameters": []}],
            }
    for mode in COMBO_MODES:
        entry = dict(cfg.get(mode) or {})
        entry["modelName"] = model
        entry["selectedModels"] = [{"modelId": model, "parameters": []}]
        entry["maxMode"] = False
        cfg[mode] = entry
    ai["modelConfig"] = cfg
    blob["aiSettings"] = ai

    con.execute(
        "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
        (
            APPLICATION_USER_KEY,
            json.dumps(blob, ensure_ascii=False, separators=(",", ":")),
        ),
    )
    con.commit()
    con.close()
    return {
        "ok": True,
        "removedKeys": removed,
        "removedFakeModels": fake,
        "baseUrl": base,
        "model": model,
    }


def main() -> int:
    model = "my-combo"
    timeout = 900.0
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "--model" and i + 1 < len(args):
            model = args[i + 1]
        elif a == "--timeout" and i + 1 < len(args):
            timeout = float(args[i + 1])

    log(f"Chờ Cursor thoát để sửa cấu hình (model={model})…")
    deadline = time.time() + timeout
    while cursor_running():
        if time.time() > deadline:
            log("Hết thời gian chờ — Cursor vẫn đang chạy, chưa sửa được.")
            return 1
        time.sleep(1.0)

    time.sleep(2.0)  # let Cursor finish flushing state.vscdb
    result = patch(model)
    log(json.dumps(result, ensure_ascii=False))
    if result.get("ok"):
        log("Xong. Mở lại Cursor và chat bình thường.")
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
