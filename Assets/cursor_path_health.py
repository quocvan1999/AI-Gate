#!/usr/bin/env python3
"""Probe Local vs Cursor path health for AI Gate."""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

APPLICATION_USER_KEY = (
    "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl"
    ".persistentStorage.applicationUser"
)


def home() -> Path:
    return Path.home()


def load_bridge() -> dict:
    path = home() / "ai-stack" / "cursor-bridge" / "status.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def http_probe(url: str, timeout: float = 4.0, headers: Optional[dict] = None) -> dict:
    req = urllib.request.Request(url, headers=headers or {"User-Agent": "AI-Gate-Health/1.0"})
    # Avoid system proxy for local/public probes when possible
    handlers = [urllib.request.ProxyHandler({})]
    opener = urllib.request.build_opener(*handlers)
    t0 = time.time()
    try:
        with opener.open(req, timeout=timeout) as resp:
            body = resp.read(2048)
            return {
                "ok": 200 <= getattr(resp, "status", 200) < 500,
                "status": getattr(resp, "status", 200),
                "ms": int((time.time() - t0) * 1000),
                "bytes": len(body),
            }
    except urllib.error.HTTPError as e:
        return {
            "ok": True,  # reached server
            "status": e.code,
            "ms": int((time.time() - t0) * 1000),
            "bytes": 0,
        }
    except Exception as e:
        return {
            "ok": False,
            "status": 0,
            "ms": int((time.time() - t0) * 1000),
            "error": str(e)[:160],
        }


def read_api_key() -> str:
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


def selected_combo_models(preferred: str) -> tuple[str, list[str]]:
    db = home() / ".9router" / "db" / "data.sqlite"
    if not db.exists():
        return preferred or "my-combo", []
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = con.execute(
            "SELECT name, models FROM combos ORDER BY updatedAt DESC"
        ).fetchall()
        con.close()
    except Exception:
        return preferred or "my-combo", []

    name = preferred or "my-combo"
    models_raw = "[]"
    names = [r[0] for r in rows]
    if name in names:
        models_raw = next(r[1] for r in rows if r[0] == name)
    elif rows:
        name = rows[0][0]
        models_raw = rows[0][1]
    try:
        models = json.loads(models_raw or "[]")
        if not isinstance(models, list):
            models = []
    except Exception:
        models = []
    return name, [str(m) for m in models]


def provider_health(combo_models: list[str]) -> list[dict]:
    db = home() / ".9router" / "db" / "data.sqlite"
    if not db.exists() or not combo_models:
        return []
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
        rows = con.execute(
            "SELECT id, provider, name, isActive, priority, data FROM providerConnections"
        ).fetchall()
        con.close()
    except Exception:
        return []

    # Map prefix (before /) -> provider rows
    by_prefix: dict[str, list] = {}
    for r in rows:
        data = {}
        try:
            data = json.loads(r["data"] or "{}")
        except Exception:
            data = {}
        prefix = (data.get("providerSpecificData") or {}).get("prefix") or r["provider"]
        prefix = str(prefix).split("/")[0]
        by_prefix.setdefault(prefix, []).append((r, data))
        by_prefix.setdefault(str(r["provider"]), []).append((r, data))

    out_list = []
    for mid in combo_models:
        prefix = mid.split("/", 1)[0]
        model_name = mid.split("/", 1)[1] if "/" in mid else mid
        matches = by_prefix.get(prefix) or []
        best = None
        for r, data in matches:
            locks = {k: v for k, v in data.items() if k.startswith("modelLock_")}
            # prefer exact model lock match
            score = 0
            if any(model_name in k or k.endswith(model_name) for k in locks):
                score = 2
            elif data.get("defaultModel") == model_name:
                score = 1
            if best is None or score > best[0]:
                best = (score, r, data, locks)
        if not best:
            out_list.append(
                {
                    "model": mid,
                    "provider": prefix,
                    "active": False,
                    "testStatus": "unknown",
                    "errorCode": None,
                    "lastError": "No matching provider connection",
                    "usable": False,
                }
            )
            continue
        _, r, data, locks = best
        err = (data.get("lastError") or "")[:140]
        code = data.get("errorCode")
        status = data.get("testStatus") or ("active" if r["isActive"] else "inactive")
        lock_hit = any(
            (model_name in k or k.endswith(model_name)) and v
            for k, v in locks.items()
        )
        usable = bool(r["isActive"]) and status in ("active", "ok", "ready", None, "") and not (
            code in (404, 503, 401, 403) and lock_hit
        )
        # treat explicit unavailable + recent error as not usable
        if status == "unavailable" or (isinstance(code, int) and code >= 400 and lock_hit):
            usable = False
        if status == "active" and not lock_hit:
            usable = True
        out_list.append(
            {
                "model": mid,
                "provider": r["provider"],
                "name": r["name"],
                "active": bool(r["isActive"]),
                "testStatus": status,
                "errorCode": code,
                "lastError": err,
                "usable": usable,
            }
        )
    return out_list


def cursor_config_match(expected_base: str, model: str) -> dict:
    db = (
        home()
        / "Library"
        / "Application Support"
        / "Cursor"
        / "User"
        / "globalStorage"
        / "state.vscdb"
    )
    if not db.exists():
        return {
            "configured": False,
            "hasDb": False,
            "baseUrl": "",
            "useOpenAIKey": False,
            "hasModel": False,
            "message": "Chưa có Cursor state DB",
        }
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        row = con.execute(
            "SELECT value FROM ItemTable WHERE key=?", (APPLICATION_USER_KEY,)
        ).fetchone()
        sec = con.execute(
            "SELECT length(value) FROM ItemTable WHERE key=?",
            ("secret://cursorAuth/openAIKey",),
        ).fetchone()
        plain = con.execute(
            "SELECT length(value) FROM ItemTable WHERE key=?",
            ("cursorAuth/openAIKey",),
        ).fetchone()
        con.close()
        if not row:
            return {
                "configured": False,
                "hasDb": True,
                "baseUrl": "",
                "useOpenAIKey": False,
                "hasModel": False,
                "message": "Thiếu applicationUser",
            }
        blob = json.loads(row[0])
        base = str(blob.get("openAIBaseUrl") or "").rstrip("/")
        use_key = bool(blob.get("useOpenAIKey"))
        ai = blob.get("aiSettings") or {}
        uam = [str(x) for x in (ai.get("userAddedModels") or [])]
        moe = [str(x) for x in (ai.get("modelOverrideEnabled") or [])]
        has_model = model in uam or model in moe
        exp = (expected_base or "").rstrip("/")
        base_ok = bool(exp) and base == exp
        has_secret = bool(sec and sec[0] and sec[0] > 10) or bool(plain and plain[0] and plain[0] > 0)
        configured = base_ok and use_key and has_model and has_secret
        msg = "Cursor khớp Bridge"
        if not base_ok:
            msg = "Base URL Cursor lệch hoặc trống"
        elif not use_key:
            msg = "OpenAI API Key chưa bật trong Cursor"
        elif not has_model:
            msg = f"Model {model} chưa có trong Cursor"
        elif not has_secret:
            msg = "Thiếu API key trong Cursor"
        return {
            "configured": configured,
            "hasDb": True,
            "baseUrl": base,
            "useOpenAIKey": use_key,
            "hasModel": has_model,
            "hasKey": has_secret,
            "message": msg,
        }
    except Exception as e:
        return {
            "configured": False,
            "hasDb": True,
            "message": f"Đọc Cursor DB lỗi: {e}"[:160],
        }


def main() -> int:
    model_arg = "my-combo"
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        model_arg = sys.argv[1]
    for i, a in enumerate(sys.argv):
        if a == "--model" and i + 1 < len(sys.argv):
            model_arg = sys.argv[i + 1]

    bridge = load_bridge()
    base = str(bridge.get("baseUrl") or "").rstrip("/")
    funnel_cli = bool(bridge.get("funnelEnabled"))
    wanted = bool(bridge.get("wanted"))

    local_dash = http_probe("http://127.0.0.1:20128/dashboard", timeout=2.5)
    local_router = local_dash.get("ok") and local_dash.get("status", 0) in (200, 301, 302, 303, 307, 308)

    key = read_api_key()
    local_api = http_probe(
        "http://127.0.0.1:20128/v1/models",
        timeout=6.0,
        headers={"Authorization": f"Bearer {key}"} if key else None,
    )
    # /v1/models can be huge/slow; treat HTTP 200/401 as reachable API
    local_api_ok = local_api.get("status") in (200, 401) or (
        local_api.get("ok") and local_api.get("status", 0) != 0
    )

    public = {"ok": False, "status": 0, "ms": 0}
    public_auth = {"ok": False, "status": 0, "ms": 0}
    if base:
        public = http_probe(f"{base}/models", timeout=8.0)
        # 401 means Funnel+router auth gate works (reachable)
        public_reachable = public.get("status") in (200, 401, 403) or (
            public.get("ok") and public.get("status", 0) != 0
        )
        if key:
            public_auth = http_probe(
                f"{base}/models",
                timeout=10.0,
                headers={"Authorization": f"Bearer {key}"},
            )
    else:
        public_reachable = False

    public_auth_ok = public_auth.get("status") == 200

    combo_name, combo_models = selected_combo_models(model_arg)
    providers = provider_health(combo_models)
    usable_count = sum(1 for p in providers if p.get("usable"))
    combo_healthy = usable_count > 0 if providers else False

    cursor = cursor_config_match(base, combo_name if model_arg == combo_name else model_arg)
    # Prefer explicit model arg for cursor match
    cursor = cursor_config_match(base, model_arg)

    cursor_path_ok = (
        (not wanted)
        or (
            funnel_cli
            and public_reachable
            and cursor.get("configured", False)
            and (combo_healthy or not providers)
        )
    )

    result = {
        "localRouter": bool(local_router),
        "localApi": bool(local_api_ok),
        "localDashboardMs": local_dash.get("ms", 0),
        "localApiMs": local_api.get("ms", 0),
        "funnelCli": funnel_cli,
        "wanted": wanted,
        "baseUrl": base,
        "publicReachable": bool(public_reachable) if base else False,
        "publicStatus": public.get("status", 0),
        "publicMs": public.get("ms", 0),
        "publicAuthenticated": bool(public_auth_ok),
        "publicAuthStatus": public_auth.get("status", 0),
        "cursorConfigured": bool(cursor.get("configured")),
        "cursorMessage": cursor.get("message", ""),
        "cursorBaseUrl": cursor.get("baseUrl", ""),
        "comboName": combo_name,
        "comboHealthy": combo_healthy,
        "usableProviders": usable_count,
        "providerCount": len(providers),
        "providers": providers[:16],
        "cursorPathOk": bool(cursor_path_ok),
        "message": _summary_message(
            local_router,
            local_api_ok,
            wanted,
            funnel_cli,
            bool(public_reachable) if base else False,
            cursor.get("configured", False),
            combo_healthy,
            providers,
        ),
    }
    print(json.dumps(result, ensure_ascii=False))
    return 0


def _summary_message(
    local_router,
    local_api,
    wanted,
    funnel_cli,
    public_reachable,
    cursor_configured,
    combo_healthy,
    providers,
) -> str:
    if not local_router:
        return "9Router local chưa sẵn sàng"
    if not local_api:
        return "Local API /v1 chậm hoặc không trả lời (Codex có thể vẫn dùng được dashboard)"
    if not wanted:
        return "Local OK • Cursor Bridge chưa bật"
    if not funnel_cli:
        return "Funnel CLI đang tắt — Cursor không vào được"
    if not public_reachable:
        return "Funnel public không tới được (Cursor sẽ Network Error; Codex local vẫn OK)"
    if not cursor_configured:
        return "Funnel OK nhưng Cursor chưa Apply đúng Base URL/key/model"
    if providers and not combo_healthy:
        return "Cursor path OK nhưng combo không còn provider usable"
    return "Local + Cursor path sẵn sàng"


if __name__ == "__main__":
    sys.exit(main())
