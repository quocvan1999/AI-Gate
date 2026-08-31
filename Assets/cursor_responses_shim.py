#!/usr/bin/env python3
"""
Cursor Responses shim for AI Gate.

9Router's /v1/responses often returns SSE `response.completed` with empty output,
so Cursor Agent hangs on "Đang suy nghĩ" while /v1/chat/completions (Test/Codex) works.

This process:
  - Listens on --listen (default 20129)
  - Proxies almost everything to --upstream (default http://127.0.0.1:20128)
  - Rewrites POST /v1/responses → upstream /v1/chat/completions and maps the reply
    back into OpenAI Responses API JSON / SSE that Cursor expects.
"""

from __future__ import annotations

import argparse
import json
import queue
import sys
import threading
import time
import uuid
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional


DUMP_PATH = Path.home() / "ai-stack" / "logs" / "cursor-responses-requests.jsonl"


def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    sys.stderr.write(f"[cursor-responses-shim {ts}] {msg}\n")
    sys.stderr.flush()


def dump_request(headers: dict, body: dict) -> None:
    """Record what Cursor actually sends so schema mismatches are visible."""
    try:
        DUMP_PATH.parent.mkdir(parents=True, exist_ok=True)
        safe_headers = {
            k: ("<redacted>" if k.lower() == "authorization" else v)
            for k, v in headers.items()
        }
        entry = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "headers": safe_headers,
            "body": body,
        }
        with DUMP_PATH.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False)[:200000] + "\n")
    except Exception:
        pass


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:24]}"


def extract_text_parts(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        chunks: list[str] = []
        for part in content:
            if isinstance(part, str):
                chunks.append(part)
            elif isinstance(part, dict):
                t = part.get("type")
                if t in ("text", "input_text", "output_text"):
                    chunks.append(str(part.get("text") or ""))
                elif "text" in part:
                    chunks.append(str(part.get("text") or ""))
                elif "content" in part:
                    chunks.append(extract_text_parts(part.get("content")))
        return "".join(chunks)
    if isinstance(content, dict):
        return extract_text_parts(content.get("text") or content.get("content"))
    return str(content)


def input_to_messages(body: dict) -> list[dict]:
    messages: list[dict] = []
    instructions = body.get("instructions")
    if isinstance(instructions, str) and instructions.strip():
        messages.append({"role": "system", "content": instructions})

    inp = body.get("input")
    if isinstance(inp, str):
        if inp.strip():
            messages.append({"role": "user", "content": inp})
        return messages

    if isinstance(inp, list):
        for item in inp:
            if isinstance(item, str):
                if item.strip():
                    messages.append({"role": "user", "content": item})
                continue
            if not isinstance(item, dict):
                continue
            # Responses API item shapes
            typ = str(item.get("type") or "")
            if typ == "message" or "role" in item:
                role = str(item.get("role") or "user")
                text = extract_text_parts(item.get("content"))
                if text or role in ("system", "developer"):
                    messages.append({"role": role if role != "developer" else "system", "content": text})
                continue
            if typ in ("input_text", "text"):
                text = str(item.get("text") or "")
                if text:
                    messages.append({"role": "user", "content": text})
                continue
            # Fallback: stringify
            text = extract_text_parts(item.get("content") or item.get("text"))
            if text:
                messages.append({"role": "user", "content": text})
        return messages

    if not messages:
        messages.append({"role": "user", "content": "hello"})
    return messages


def map_tools(body: dict) -> Optional[list]:
    tools = body.get("tools")
    if not isinstance(tools, list) or not tools:
        return None
    out = []
    for t in tools:
        if not isinstance(t, dict):
            continue
        # Already chat-completions shaped
        if t.get("type") == "function" and isinstance(t.get("function"), dict):
            out.append(t)
            continue
        # Responses-shaped: {type:"function", name, description, parameters}
        if t.get("type") == "function" and t.get("name"):
            out.append(
                {
                    "type": "function",
                    "function": {
                        "name": t.get("name"),
                        "description": t.get("description") or "",
                        "parameters": t.get("parameters") or {"type": "object", "properties": {}},
                    },
                }
            )
    return out or None


def assistant_text_from_chat(chat: dict) -> str:
    choices = chat.get("choices") or []
    if not choices:
        return ""
    msg = (choices[0] or {}).get("message") or {}
    content = msg.get("content")
    if isinstance(content, str) and content.strip():
        return content
    # Many combo providers return reasoning_content with empty content
    reasoning = msg.get("reasoning_content") or msg.get("reasoning")
    if isinstance(reasoning, str) and reasoning.strip():
        return reasoning
    return extract_text_parts(content)


def tool_calls_from_chat(chat: dict) -> list[dict]:
    choices = chat.get("choices") or []
    if not choices:
        return []
    msg = (choices[0] or {}).get("message") or {}
    raw = msg.get("tool_calls")
    if not isinstance(raw, list):
        return []
    out: list[dict] = []
    for tc in raw:
        if not isinstance(tc, dict):
            continue
        fn = tc.get("function") or {}
        call_id = str(tc.get("id") or new_id("call"))
        out.append(
            {
                "id": call_id,
                "type": "function_call",
                "status": "completed",
                "call_id": call_id,
                "name": str(fn.get("name") or "unknown"),
                "arguments": str(fn.get("arguments") or "{}"),
            }
        )
    return out


def response_envelope(
    rid: str,
    model: str,
    status: str,
    request: Optional[dict] = None,
    *,
    output: Optional[list] = None,
    usage: Optional[dict] = None,
    created_at: Optional[int] = None,
) -> dict:
    """Full Responses envelope. Cursor validates required fields and drops the
    stream (rpc.run error ~900ms) when the echoed request params are missing."""
    body = request or {}
    text_cfg = body.get("text")
    if not isinstance(text_cfg, dict):
        text_cfg = {"format": {"type": "text"}}
    reasoning_cfg = body.get("reasoning")
    if not isinstance(reasoning_cfg, dict):
        reasoning_cfg = {"effort": None, "summary": None}
    metadata = body.get("metadata")
    if not isinstance(metadata, dict):
        metadata = {}
    tool_choice = body.get("tool_choice")
    if tool_choice is None:
        tool_choice = "auto"
    env = {
        "id": rid,
        "object": "response",
        "created_at": created_at if created_at is not None else int(time.time()),
        "status": status,
        "background": bool(body.get("background") or False),
        "error": None,
        "incomplete_details": None,
        "instructions": body.get("instructions"),
        "max_output_tokens": body.get("max_output_tokens"),
        "max_tool_calls": body.get("max_tool_calls"),
        "model": model,
        "output": output if output is not None else [],
        "parallel_tool_calls": bool(body.get("parallel_tool_calls", True)),
        "previous_response_id": body.get("previous_response_id"),
        "prompt_cache_key": body.get("prompt_cache_key"),
        "reasoning": reasoning_cfg,
        "safety_identifier": body.get("safety_identifier"),
        "service_tier": body.get("service_tier") or "default",
        "store": bool(body.get("store") or False),
        "temperature": body.get("temperature") if body.get("temperature") is not None else 1,
        "text": text_cfg,
        "tool_choice": tool_choice,
        "tools": body.get("tools") or [],
        "top_logprobs": body.get("top_logprobs") or 0,
        "top_p": body.get("top_p") if body.get("top_p") is not None else 1,
        "truncation": body.get("truncation") or "disabled",
        "user": body.get("user"),
        "metadata": metadata,
        "usage": usage,
    }
    return env


def usage_from_chat(chat: Optional[dict]) -> dict:
    raw = (chat or {}).get("usage") or {}
    return {
        "input_tokens": raw.get("prompt_tokens") or 0,
        "input_tokens_details": {"cached_tokens": 0},
        "output_tokens": raw.get("completion_tokens") or 0,
        "output_tokens_details": {"reasoning_tokens": 0},
        "total_tokens": raw.get("total_tokens") or 0,
    }


def build_response_object(
    model: str,
    text: str,
    chat: Optional[dict] = None,
    *,
    tool_items: Optional[list[dict]] = None,
    request: Optional[dict] = None,
    rid: Optional[str] = None,
    created_at: Optional[int] = None,
) -> dict:
    mid = new_id("msg")
    tools = tool_items if tool_items is not None else tool_calls_from_chat(chat or {})
    output: list[dict] = []
    if text or not tools:
        output.append(
            {
                "id": mid,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [
                    {
                        "type": "output_text",
                        "text": text or "",
                        "annotations": [],
                    }
                ],
            }
        )
    output.extend(tools)
    return response_envelope(
        rid or new_id("resp"),
        model or ((chat or {}).get("model") or ""),
        "completed",
        request,
        output=output,
        usage=usage_from_chat(chat),
        created_at=created_at,
    )


def sse(event: str, data: dict) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode("utf-8")


class ShimHandler(BaseHTTPRequestHandler):
    upstream: str = "http://127.0.0.1:20128"

    def log_message(self, fmt: str, *args: Any) -> None:
        log(f"{self.address_string()} {fmt % args}")

    def _read_body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _is_responses(self) -> bool:
        path = self.path.split("?", 1)[0]
        return path.rstrip("/") in ("/v1/responses", "/responses") or path.startswith(
            "/v1/responses/"
        )

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def do_GET(self) -> None:
        self._proxy()

    def do_POST(self) -> None:
        if self._is_responses() and not self.path.split("?", 1)[0].rstrip("/").endswith(
            "/compact"
        ):
            self._handle_responses()
            return
        self._proxy()

    def do_PUT(self) -> None:
        self._proxy()

    def do_DELETE(self) -> None:
        self._proxy()

    def do_PATCH(self) -> None:
        self._proxy()

    def _proxy(self) -> None:
        body = self._read_body()
        url = f"{self.upstream}{self.path}"
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "content-length", "transfer-encoding", "connection")
        }
        req = urllib.request.Request(url, data=body if body else None, headers=headers, method=self.command)
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                status = getattr(resp, "status", 200)
                self.send_response(status)
                ct = resp.headers.get("Content-Type") or ""
                is_stream = "text/event-stream" in ct.lower()
                for k, v in resp.headers.items():
                    lk = k.lower()
                    if lk in ("transfer-encoding", "connection", "content-encoding"):
                        continue
                    if is_stream and lk == "content-length":
                        continue
                    self.send_header(k, v)
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()

                if is_stream:
                    while True:
                        line = resp.readline()
                        if not line:
                            break
                        self.wfile.write(line)
                        self.wfile.flush()
                else:
                    data = resp.read()
                    self.wfile.write(data)
                    self.wfile.flush()
        except urllib.error.HTTPError as e:
            data = e.read() if hasattr(e, "read") else b""
            try:
                self.send_response(int(e.code))
                self.send_header("Content-Type", e.headers.get("Content-Type") or "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except BrokenPipeError:
                pass
        except BrokenPipeError:
            pass
        except Exception as e:
            payload = json.dumps({"error": {"message": str(e), "type": "shim_proxy_error"}}).encode()
            try:
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except BrokenPipeError:
                pass

    def _handle_responses(self) -> None:
        raw = self._read_body()
        try:
            body = json.loads(raw.decode("utf-8") if raw else "{}")
        except Exception:
            body = {}
        if not isinstance(body, dict):
            body = {}

        model = str(body.get("model") or "my-combo")
        want_stream = bool(body["stream"]) if "stream" in body else True
        messages = input_to_messages(body)
        chat_body: dict[str, Any] = {
            "model": model,
            "messages": messages,
            "stream": want_stream,
        }
        max_out = body.get("max_output_tokens") or body.get("max_tokens")
        if max_out:
            chat_body["max_tokens"] = max_out
        tools = map_tools(body)
        if tools:
            chat_body["tools"] = tools
        if body.get("tool_choice") is not None:
            chat_body["tool_choice"] = body.get("tool_choice")
        if body.get("temperature") is not None:
            chat_body["temperature"] = body.get("temperature")

        auth = self.headers.get("Authorization") or ""
        headers = {
            "Content-Type": "application/json",
            "Authorization": auth,
            "User-Agent": self.headers.get("User-Agent") or "AI-Gate-CursorResponsesShim/1.0",
        }
        has_auth = bool(auth.strip()) and not auth.strip().lower() in ("bearer", "bearer ")
        log(
            f"responses rewrite model={model} stream={want_stream} "
            f"msgs={len(messages)} tools={len(tools or [])} auth={'yes' if has_auth else 'NO'} "
            f"ua={self.headers.get('User-Agent') or '-'}"
        )
        dump_request(dict(self.headers), body)

        url = f"{self.upstream}/v1/chat/completions"
        data = json.dumps(chat_body).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")

        try:
            if want_stream:
                self._stream_responses(req, model, has_tools=bool(tools), request=body)
            else:
                self._json_responses(req, model, request=body)
        except BrokenPipeError:
            log("client disconnected during /v1/responses")
            return
        except urllib.error.HTTPError as e:
            if getattr(self, "wfile", None) and getattr(self, "headers_sent", False):
                log(f"upstream HTTP {e.code} after headers sent — abort")
                return
            err = e.read() if hasattr(e, "read") else b""
            try:
                self.send_response(int(e.code))
                self.send_header("Content-Type", e.headers.get("Content-Type") or "application/json")
                self.send_header("Content-Length", str(len(err)))
                self.end_headers()
                self.wfile.write(err)
            except BrokenPipeError:
                return
        except Exception as e:
            log(f"responses error: {e}")
            if getattr(self, "headers_sent", False):
                return
            payload = json.dumps(
                {"error": {"message": f"responses shim failed: {e}", "type": "shim_error"}}
            ).encode()
            try:
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except BrokenPipeError:
                return

    def _json_responses(
        self, req: urllib.request.Request, model: str, *, request: Optional[dict] = None
    ) -> None:
        with urllib.request.urlopen(req, timeout=600) as resp:
            raw = resp.read()
        try:
            chat = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            chat = {}
        text = assistant_text_from_chat(chat if isinstance(chat, dict) else {})
        obj = build_response_object(
            model,
            text,
            chat if isinstance(chat, dict) else None,
            request=request,
        )
        out = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def _emit(self, event: str, data: dict) -> None:
        self.wfile.write(sse(event, data))
        self.wfile.flush()

    def _stream_responses(
        self,
        req: urllib.request.Request,
        model: str,
        *,
        has_tools: bool = False,
        request: Optional[dict] = None,
    ) -> None:
        """Stream Responses SSE. Cursor Agent rpc.run times out ~1.3s without a real progress event."""
        self.headers_sent = False
        rid = new_id("resp")
        mid = new_id("msg")
        now = int(time.time())
        seq = 0
        t0 = time.time()
        emit_lock = threading.Lock()
        heartbeat_stop = threading.Event()
        first_token_evt = threading.Event()

        def next_seq() -> int:
            nonlocal seq
            seq += 1
            return seq

        # Start upstream immediately so first provider token overlaps with prelude SSE.
        line_q: queue.Queue = queue.Queue()

        def upstream_reader() -> None:
            try:
                with urllib.request.urlopen(req, timeout=600) as resp:
                    while True:
                        line = resp.readline()
                        if not line:
                            break
                        line_q.put(("line", line))
                line_q.put(("end", None))
            except Exception as e:
                line_q.put(("err", e))

        threading.Thread(target=upstream_reader, daemon=True).start()

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.headers_sent = True

        base_resp = response_envelope(
            rid, model, "in_progress", request, created_at=now
        )
        self._emit(
            "response.created",
            {
                "type": "response.created",
                "response": json.loads(json.dumps(base_resp)),
                "sequence_number": next_seq(),
            },
        )
        self._emit(
            "response.in_progress",
            {
                "type": "response.in_progress",
                "response": json.loads(json.dumps(base_resp)),
                "sequence_number": next_seq(),
            },
        )

        msg_output_index = 0
        priming = "\u200b"

        item = {
            "id": mid,
            "type": "message",
            "status": "in_progress",
            "role": "assistant",
            "content": [],
        }
        self._emit(
            "response.output_item.added",
            {
                "type": "response.output_item.added",
                "output_index": msg_output_index,
                "item": item,
                "sequence_number": next_seq(),
            },
        )
        self._emit(
            "response.content_part.added",
            {
                "type": "response.content_part.added",
                "item_id": mid,
                "output_index": msg_output_index,
                "content_index": 0,
                "part": {"type": "output_text", "text": "", "annotations": []},
                "sequence_number": next_seq(),
            },
        )
        # Zero-width prelude keeps Cursor's 20s network_ttft alive on cold providers.
        self._emit(
            "response.output_text.delta",
            {
                "type": "response.output_text.delta",
                "item_id": mid,
                "output_index": msg_output_index,
                "content_index": 0,
                "delta": priming,
                "sequence_number": next_seq(),
            },
        )
        self.wfile.write(b": " + (b" " * 2048) + b"\n\n")
        self.wfile.flush()
        log(
            f"stream prelude flushed in {int((time.time() - t0) * 1000)}ms "
            f"model={model} tools={'yes' if has_tools else 'no'}"
        )

        full_text: list[str] = [priming]
        first_real_ms: Optional[int] = None
        tool_states: dict[int, dict[str, Any]] = {}
        next_fc_output_index = msg_output_index + 1
        ended = False

        def maybe_emit_tool_added(state: dict[str, Any]) -> None:
            if state.get("added"):
                return
            if not state.get("name"):
                return
            if not state.get("call_id"):
                state["call_id"] = new_id("call")
            state["added"] = True
            item = {
                "id": state["item_id"],
                "type": "function_call",
                "status": "in_progress",
                "call_id": state["call_id"],
                "name": state["name"],
            }
            self._emit(
                "response.output_item.added",
                {
                    "type": "response.output_item.added",
                    "output_index": state["output_index"],
                    "item": item,
                    "sequence_number": next_seq(),
                },
            )

        def process_tool_call_delta(tc: dict[str, Any]) -> None:
            nonlocal next_fc_output_index, first_real_ms
            idx = int(tc.get("index") or 0)
            if idx not in tool_states:
                tool_states[idx] = {
                    "item_id": new_id("fc"),
                    "call_id": str(tc.get("id") or ""),
                    "name": "",
                    "arguments": "",
                    "output_index": next_fc_output_index,
                    "added": False,
                }
                next_fc_output_index += 1
            state = tool_states[idx]
            if tc.get("id"):
                state["call_id"] = str(tc["id"])
            fn = tc.get("function") or {}
            if fn.get("name"):
                state["name"] = str(fn["name"])
            arg_piece = fn.get("arguments")
            if isinstance(arg_piece, str) and arg_piece:
                maybe_emit_tool_added(state)
                if state.get("added"):
                    if first_real_ms is None:
                        first_real_ms = int((time.time() - t0) * 1000)
                        first_token_evt.set()
                        heartbeat_stop.set()
                        log(f"first upstream tool args at {first_real_ms}ms")
                    state["arguments"] += arg_piece
                    self._emit(
                        "response.function_call_arguments.delta",
                        {
                            "type": "response.function_call_arguments.delta",
                            "item_id": state["item_id"],
                            "output_index": state["output_index"],
                            "delta": arg_piece,
                            "sequence_number": next_seq(),
                        },
                    )
            elif state.get("name") and not state.get("added"):
                maybe_emit_tool_added(state)
                if first_real_ms is None and state.get("added"):
                    first_real_ms = int((time.time() - t0) * 1000)
                    first_token_evt.set()
                    heartbeat_stop.set()
                    log(f"first upstream tool call at {first_real_ms}ms")

        while not ended:
            try:
                kind, payload = line_q.get(timeout=1.0)
            except queue.Empty:
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
                continue
            if kind == "err":
                err_txt = f"\n[shim upstream error: {payload}]"
                full_text.append(err_txt)
                self._emit(
                    "response.output_text.delta",
                    {
                        "type": "response.output_text.delta",
                        "item_id": mid,
                        "output_index": 0,
                        "content_index": 0,
                        "delta": err_txt,
                        "sequence_number": next_seq(),
                    },
                )
                break
            if kind == "end":
                ended = True
                break
            line = payload
            s = line.decode("utf-8", "replace").strip()
            if not s or s.startswith(":") or not s.startswith("data:"):
                continue
            data_s = s[5:].strip()
            if data_s == "[DONE]":
                ended = True
                break
            try:
                chunk = json.loads(data_s)
            except Exception:
                continue
            choices = chunk.get("choices") or []
            if not choices:
                continue
            delta = (choices[0] or {}).get("delta") or {}
            for tc in delta.get("tool_calls") or []:
                if isinstance(tc, dict):
                    process_tool_call_delta(tc)
            piece = delta.get("content")
            if not piece:
                piece = delta.get("reasoning_content") or delta.get("reasoning")
            if not isinstance(piece, str) or not piece:
                continue
            if first_real_ms is None:
                first_real_ms = int((time.time() - t0) * 1000)
                first_token_evt.set()
                heartbeat_stop.set()
                log(f"first upstream token at {first_real_ms}ms")
            full_text.append(piece)
            self._emit(
                "response.output_text.delta",
                {
                    "type": "response.output_text.delta",
                    "item_id": mid,
                    "output_index": msg_output_index,
                    "content_index": 0,
                    "delta": piece,
                    "sequence_number": next_seq(),
                },
            )

        heartbeat_stop.set()
        text = "".join(full_text).lstrip("\u200b")
        self._emit(
            "response.output_text.done",
            {
                "type": "response.output_text.done",
                "item_id": mid,
                "output_index": msg_output_index,
                "content_index": 0,
                "text": text,
                "sequence_number": next_seq(),
            },
        )
        self._emit(
            "response.content_part.done",
            {
                "type": "response.content_part.done",
                "item_id": mid,
                "output_index": msg_output_index,
                "content_index": 0,
                "part": {"type": "output_text", "text": text, "annotations": []},
                "sequence_number": next_seq(),
            },
        )
        done_item = {
            "id": mid,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text, "annotations": []}],
        }
        self._emit(
            "response.output_item.done",
            {
                "type": "response.output_item.done",
                "output_index": msg_output_index,
                "item": done_item,
                "sequence_number": next_seq(),
            },
        )

        tool_items: list[dict] = []
        for idx in sorted(tool_states.keys()):
            state = tool_states[idx]
            if not state.get("name"):
                state["name"] = "unknown"
            if not state.get("call_id"):
                state["call_id"] = new_id("call")
            maybe_emit_tool_added(state)
            args = state.get("arguments") or "{}"
            self._emit(
                "response.function_call_arguments.done",
                {
                    "type": "response.function_call_arguments.done",
                    "item_id": state["item_id"],
                    "output_index": state["output_index"],
                    "name": state["name"],
                    "arguments": args,
                    "sequence_number": next_seq(),
                },
            )
            fc_done = {
                "id": state["item_id"],
                "type": "function_call",
                "status": "completed",
                "call_id": state["call_id"],
                "name": state["name"],
                "arguments": args,
            }
            self._emit(
                "response.output_item.done",
                {
                    "type": "response.output_item.done",
                    "output_index": state["output_index"],
                    "item": fc_done,
                    "sequence_number": next_seq(),
                },
            )
            tool_items.append(fc_done)

        completed = build_response_object(
            model,
            text,
            None,
            tool_items=tool_items,
            request=request,
            rid=rid,
            created_at=now,
        )
        self._emit(
            "response.completed",
            {"type": "response.completed", "response": completed, "sequence_number": next_seq()},
        )
        log(
            f"stream done total={int((time.time() - t0) * 1000)}ms "
            f"first_real={first_real_ms} chars={len(text)} tools={len(tool_items)}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="AI Gate Cursor /v1/responses shim")
    parser.add_argument("--listen", type=int, default=20129)
    parser.add_argument("--upstream", default="http://127.0.0.1:20128")
    parser.add_argument("--bind", default="127.0.0.1")
    args = parser.parse_args()

    ShimHandler.upstream = args.upstream.rstrip("/")
    server = ThreadingHTTPServer((args.bind, args.listen), ShimHandler)
    log(f"listening on http://{args.bind}:{args.listen} → {ShimHandler.upstream}")
    log("rewriting POST /v1/responses → /v1/chat/completions")

    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    try:
        while t.is_alive():
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
