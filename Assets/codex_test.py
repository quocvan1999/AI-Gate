#!/usr/bin/env python3
"""Real Codex path test: config.toml model + local 9Router /v1/models + chat ping."""

from __future__ import annotations

import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def out(**extra) -> int:
    print(json.dumps(extra, ensure_ascii=False))
    return 0 if extra.get("ok") else 1


def read_codex_model() -> str:
    path = Path.home() / ".codex" / "config.toml"
    if not path.exists():
        return ""
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return ""
    m = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"\s*$', text)
    if m:
        return m.group(1).strip()
    m = re.search(r"(?m)^\s*model\s*=\s*'([^']+)'\s*$", text)
    return m.group(1).strip() if m else ""


def read_api_key() -> str:
    db = Path.home() / ".9router" / "db" / "data.sqlite"
    if not db.exists():
        return ""
    try:
        import sqlite3

        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        row = con.execute(
            "SELECT key FROM apiKeys WHERE isActive=1 ORDER BY createdAt ASC LIMIT 1"
        ).fetchone()
        con.close()
        return (row[0] if row else "") or ""
    except Exception:
        return ""


def http_json(method: str, url: str, key: str, body: dict | None = None, timeout: float = 20.0):
    data = None
    headers = {"Authorization": f"Bearer {key}"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            ms = int((time.time() - t0) * 1000)
            try:
                parsed = json.loads(raw.decode("utf-8", errors="replace"))
            except Exception:
                parsed = {"_raw": raw[:300].decode("utf-8", errors="replace")}
            return resp.status, ms, parsed, ""
    except urllib.error.HTTPError as e:
        ms = int((time.time() - t0) * 1000)
        raw = e.read() if hasattr(e, "read") else b""
        try:
            parsed = json.loads(raw.decode("utf-8", errors="replace"))
        except Exception:
            parsed = {"_raw": raw[:300].decode("utf-8", errors="replace")}
        return int(e.code), ms, parsed, str(e)
    except Exception as e:
        ms = int((time.time() - t0) * 1000)
        return 0, ms, {}, str(e)


def main() -> int:
    preferred = "my-combo"
    for i, a in enumerate(sys.argv):
        if a == "--model" and i + 1 < len(sys.argv):
            preferred = sys.argv[i + 1].strip() or preferred

    cfg_model = read_codex_model()
    model = preferred or cfg_model or "my-combo"
    key = read_api_key()
    if not key:
        return out(
            ok=False,
            message="Thiếu API key 9Router",
            model=model,
            configModel=cfg_model,
            latencyMs=0,
        )

    status_m, ms_m, models_body, err_m = http_json(
        "GET", "http://127.0.0.1:20128/v1/models", key, timeout=8.0
    )
    ids = []
    if isinstance(models_body, dict):
        ids = [str(x.get("id") or "") for x in (models_body.get("data") or []) if isinstance(x, dict)]
    has_model = model in ids

    status_c, ms_c, chat_body, err_c = http_json(
        "POST",
        "http://127.0.0.1:20128/v1/chat/completions",
        key,
        body={
            "model": model,
            "messages": [{"role": "user", "content": "ping"}],
            "max_tokens": 1,
        },
        timeout=25.0,
    )
    chat_ok = 200 <= status_c < 300
    models_ok = 200 <= status_m < 300 and has_model
    ok = models_ok and chat_ok
    latency = ms_m + ms_c

    msg = (
        f"Codex OK — «{model}» chat HTTP {status_c}, {latency} ms"
        if ok
        else (
            f"Codex: models HTTP {status_m} (combo={has_model}), chat HTTP {status_c}"
        )
    )
    detail = ""
    if not chat_ok:
        if isinstance(chat_body, dict) and chat_body.get("error"):
            detail = json.dumps(chat_body.get("error"), ensure_ascii=False)[:240]
        elif err_c:
            detail = err_c[:240]
        elif err_m:
            detail = err_m[:240]

    return out(
        ok=ok,
        message=msg,
        detail=detail,
        model=model,
        configModel=cfg_model,
        configMatches=bool(cfg_model) and cfg_model == model,
        modelsStatus=status_m,
        chatStatus=status_c,
        hasModel=has_model,
        latencyMs=latency,
        modelsMs=ms_m,
        chatMs=ms_c,
    )


if __name__ == "__main__":
    sys.exit(main())
