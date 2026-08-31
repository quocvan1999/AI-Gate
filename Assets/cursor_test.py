#!/usr/bin/env python3
"""Test Cursor path: Funnel public URL (nếu có) + chat/responses ping combo đang apply."""

from __future__ import annotations

import json
import socket
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def out(**extra) -> int:
    print(json.dumps(extra, ensure_ascii=False))
    return 0 if extra.get("ok") else 1


def home() -> Path:
    return Path.home()


def port_open(host: str, port: int, timeout: float = 0.4) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def read_api_key() -> str:
    db = home() / ".9router" / "db" / "data.sqlite"
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


def read_bridge_base() -> str:
    path = home() / "ai-stack" / "cursor-bridge" / "status.json"
    if not path.exists():
        return ""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return str(data.get("baseUrl") or "").rstrip("/")
    except Exception:
        return ""


def http_json(method: str, url: str, key: str, body: dict | None = None, timeout: float = 20.0):
    data = None
    headers = {
        "Authorization": f"Bearer {key}",
        "User-Agent": "AI-Gate-CursorTest/1.0",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    t0 = time.time()
    try:
        with opener.open(req, timeout=timeout) as resp:
            raw = resp.read(8000)
            ms = int((time.time() - t0) * 1000)
            try:
                parsed = json.loads(raw.decode("utf-8", errors="replace"))
            except Exception:
                parsed = {"_raw": raw[:300].decode("utf-8", errors="replace")}
            return getattr(resp, "status", 200), ms, parsed, ""
    except urllib.error.HTTPError as e:
        ms = int((time.time() - t0) * 1000)
        raw = e.read(800) if hasattr(e, "read") else b""
        try:
            parsed = json.loads(raw.decode("utf-8", errors="replace")) if raw else {}
        except Exception:
            parsed = {"_raw": (raw or b"")[:300].decode("utf-8", errors="replace")}
        return int(e.code), ms, parsed, str(e)
    except Exception as e:
        ms = int((time.time() - t0) * 1000)
        return 0, ms, {}, str(e)


def responses_text(body: dict) -> str:
    if not isinstance(body, dict):
        return ""
    out_items = body.get("output") or []
    chunks: list[str] = []
    for item in out_items:
        if not isinstance(item, dict):
            continue
        for part in item.get("content") or []:
            if isinstance(part, dict) and part.get("type") in ("output_text", "text"):
                chunks.append(str(part.get("text") or ""))
    if chunks:
        return "".join(chunks).strip()
    # Some providers fold text into top-level fields
    return str(body.get("output_text") or "").strip()


def stream_responses_ttft(
    base: str, key: str, model: str, timeout: float = 35.0
) -> tuple[int, int, str]:
    """Agent-like streaming /v1/responses — đo thời gian tới SSE đầu tiên (giống Cursor network_ttft ~20s)."""
    body = {
        "model": model,
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "ping"}],
            }
        ],
        "stream": True,
        "max_output_tokens": 32,
        "tools": [
            {
                "type": "function",
                "name": "run_terminal_cmd",
                "description": "run shell",
                "parameters": {"type": "object", "properties": {"command": {"type": "string"}}},
            }
        ],
    }
    req = urllib.request.Request(
        f"{base}/responses",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "User-Agent": "AI-Gate-CursorTest/1.0",
        },
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    t0 = time.time()
    first_ms = 0
    status = 0
    try:
        with opener.open(req, timeout=timeout) as resp:
            status = getattr(resp, "status", 200)
            while True:
                line = resp.readline()
                if not line:
                    break
                s = line.decode("utf-8", "replace").strip()
                if s.startswith("data:") and first_ms == 0:
                    first_ms = int((time.time() - t0) * 1000)
                    break
        total_ms = int((time.time() - t0) * 1000)
        return status, first_ms or total_ms, ""
    except urllib.error.HTTPError as e:
        ms = int((time.time() - t0) * 1000)
        return int(e.code), ms, str(e)[:200]
    except Exception as e:
        ms = int((time.time() - t0) * 1000)
        return 0, ms, str(e)[:200]


def main() -> int:
    preferred = "my-combo"
    for i, a in enumerate(sys.argv):
        if a == "--model" and i + 1 < len(sys.argv):
            preferred = sys.argv[i + 1].strip() or preferred

    model = preferred or "my-combo"
    key = read_api_key()
    if not key:
        return out(ok=False, message="Thiếu API key 9Router", model=model, latencyMs=0)

    public_base = read_bridge_base()
    # Cursor Agent: IDE → Cursor cloud → Funnel https URL (localhost không dùng được).
    # Ưu tiên test public Funnel; fallback shim/local chỉ để debug máy.
    if public_base:
        base = public_base
        via = "public"
    elif port_open("127.0.0.1", 20129):
        base = "http://127.0.0.1:20129/v1"
        via = "shim"
    else:
        base = "http://127.0.0.1:20128/v1"
        via = "local"

    status_m, ms_m, models_body, err_m = http_json(
        "GET", f"{base}/models", key, timeout=12.0
    )
    ids = []
    if isinstance(models_body, dict):
        ids = [
            str(x.get("id") or "")
            for x in (models_body.get("data") or [])
            if isinstance(x, dict)
        ]
    has_model = model in ids

    status_c, ms_c, chat_body, err_c = http_json(
        "POST",
        f"{base}/chat/completions",
        key,
        body={
            "model": model,
            "messages": [{"role": "user", "content": "ping"}],
            "max_tokens": 16,
        },
        timeout=28.0,
    )
    chat_ok = 200 <= status_c < 300

    # Cursor Agent gọi /v1/responses — đây là chỗ 9Router hay trả output rỗng.
    status_r, ms_r, resp_body, err_r = http_json(
        "POST",
        f"{base}/responses",
        key,
        body={
            "model": model,
            "input": "ping",
            "stream": False,
            "max_output_tokens": 32,
        },
        timeout=45.0,
    )
    resp_ok = 200 <= status_r < 300
    resp_text = responses_text(resp_body if isinstance(resp_body, dict) else {})
    responses_has_output = bool(resp_text)

    # Agent thật dùng stream + tools; Cursor cắt ~20s (network_ttft) nếu chậm.
    stream_status, stream_ttft_ms, stream_err = stream_responses_ttft(base, key, model)
    stream_ok = 200 <= stream_status < 300 and stream_ttft_ms > 0

    models_ok = status_m in (200, 401) or (200 <= status_m < 300)
    # Agent path: stream TTFT phải < ~18s (Cursor cloud timeout ~20s).
    CURSOR_AGENT_TTFT_FAIL_MS = 18_000
    CURSOR_AGENT_TTFT_WARN_MS = 12_000
    slow_for_agent = stream_ok and stream_ttft_ms >= CURSOR_AGENT_TTFT_WARN_MS
    too_slow_for_agent = stream_ok and stream_ttft_ms >= CURSOR_AGENT_TTFT_FAIL_MS
    ok = chat_ok and resp_ok and responses_has_output and stream_ok and not too_slow_for_agent
    latency = ms_m + ms_c + ms_r + stream_ttft_ms

    if ok and slow_for_agent:
        msg = (
            f"Cursor OK nhưng stream chậm ({stream_ttft_ms} ms) — "
            f"Agent dễ Network Error khi >20s."
        )
    elif too_slow_for_agent:
        msg = (
            f"Cursor stream quá chậm ({stream_ttft_ms} ms) — "
            f"vượt ngưỡng Agent (~20s) → Network Error."
        )
    elif not stream_ok:
        msg = (
            f"Cursor: stream /v1/responses HTTP {stream_status} "
            f"({stream_ttft_ms} ms)"
        )
    elif ok:
        msg = (
            f"Cursor OK — «{model}» via {via} stream TTFT {stream_ttft_ms} ms, "
            f"responses OK ({len(resp_text)} chars)"
        )
    elif chat_ok and resp_ok and not responses_has_output:
        msg = (
            f"Cursor: chat OK nhưng /v1/responses trống — Agent treo. "
            f"Funnel phải qua shim :20129 (không trỏ thẳng 9Router)."
        )
    else:
        msg = (
            f"Cursor: {via} models HTTP {status_m}, chat HTTP {status_c}, "
            f"responses HTTP {status_r}"
        )

    detail = ""
    if not ok:
        if chat_ok and resp_ok and not responses_has_output:
            detail = (
                "9Router /v1/responses đang trả rỗng/reasoning. "
                "AI Gate dùng shim :20129 trên Funnel để sửa — bật «Dùng với Cursor»."
            )
        elif isinstance(resp_body, dict) and resp_body.get("error"):
            detail = json.dumps(resp_body.get("error"), ensure_ascii=False)[:240]
        elif isinstance(chat_body, dict) and chat_body.get("error"):
            detail = json.dumps(chat_body.get("error"), ensure_ascii=False)[:240]
        elif err_r:
            detail = err_r[:240]
        elif stream_err:
            detail = stream_err[:240]
        elif err_c:
            detail = err_c[:240]
        elif err_m:
            detail = err_m[:240]
    elif slow_for_agent or too_slow_for_agent:
        detail = (
            "Cursor Agent timeout ~20s (network_ttft). Giảm model trong combo, "
            "bỏ provider chết, tắt Max Mode, hoặc bấm Test lại sau khi Bridge warmup."
        )

    return out(
        ok=ok,
        message=msg,
        detail=detail,
        model=model,
        baseUrl=base,
        via=via,
        public=bool(public_base),
        modelsStatus=status_m,
        chatStatus=status_c,
        responsesStatus=status_r,
        responsesHasOutput=responses_has_output,
        responsesPreview=(resp_text[:80] if resp_text else ""),
        hasModel=has_model,
        modelsOk=models_ok,
        latencyMs=latency,
        modelsMs=ms_m,
        chatMs=ms_c,
        responsesMs=ms_r,
        streamStatus=stream_status,
        streamTtftMs=stream_ttft_ms,
        slowForAgent=slow_for_agent or too_slow_for_agent,
        warn=slow_for_agent or too_slow_for_agent,
    )


if __name__ == "__main__":
    sys.exit(main())
