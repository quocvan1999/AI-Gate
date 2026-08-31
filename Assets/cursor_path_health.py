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


CURSOR_SHIM_BASE = "http://127.0.0.1:20129/v1"
CURSOR_LOCAL_BASE = "http://127.0.0.1:20128/v1"


def load_bridge() -> dict:
    path = home() / "ai-stack" / "cursor-bridge" / "status.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def _port_listening(port: int, host: str = "127.0.0.1") -> bool:
    import socket

    try:
        with socket.create_connection((host, port), timeout=0.3):
            return True
    except OSError:
        return False


def expected_cursor_base_url() -> str:
    """Public Funnel /v1 URL written into Cursor (Cursor cloud cannot reach localhost)."""
    return str(load_bridge().get("baseUrl") or "").rstrip("/")


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


def _mint_dashboard_jwt() -> str:
    """JWT cookie auth_token — cùng secret dashboard 9Router (local)."""
    path = home() / ".9router" / "jwt-secret"
    try:
        secret = path.read_text().strip().encode()
    except Exception:
        return ""
    if not secret:
        return ""
    import base64
    import hashlib
    import hmac
    import time

    def b64url(raw: bytes) -> str:
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    now = int(time.time())
    header = b64url(b'{"alg":"HS256"}')
    payload = b64url(
        json.dumps(
            {"authenticated": True, "iat": now, "exp": now + 86400},
            separators=(",", ":"),
        ).encode()
    )
    sig = b64url(hmac.new(secret, f"{header}.{payload}".encode(), hashlib.sha256).digest())
    return f"{header}.{payload}.{sig}"


def selected_combo_models(preferred: str) -> tuple[str, list[str]]:
    """Ưu tiên GET /api/combos (cùng nguồn UI 9Router); fallback SQLite."""
    want = preferred or "my-combo"
    token = _mint_dashboard_jwt()
    if token:
        try:
            req = urllib.request.Request(
                "http://127.0.0.1:20128/api/combos",
                headers={
                    "Cookie": f"auth_token={token}",
                    "User-Agent": "AI-Gate-Health/1.0",
                },
            )
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=3) as resp:
                body = json.loads(resp.read().decode("utf-8", "replace"))
            combos = body.get("combos") or []
            # 9Router combos page: !kind || kind === "llm"
            llm = [c for c in combos if not c.get("kind") or c.get("kind") == "llm"]
            pick = next((c for c in llm if c.get("name") == want), None) or (llm[0] if llm else None)
            if pick:
                name = str(pick.get("name") or want)
                models = pick.get("models") or []
                if isinstance(models, list) and models:
                    return name, [str(m) for m in models]
        except Exception:
            pass

    db = home() / ".9router" / "db" / "data.sqlite"
    if not db.exists():
        return want, []
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = con.execute(
            "SELECT name, models FROM combos ORDER BY updatedAt DESC"
        ).fetchall()
        con.close()
    except Exception:
        return want, []

    name = want
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


def find_9router_package_root():
    """Locate installed 9router package (npm global / relative to running binary)."""
    global _PACKAGE_ROOT_CACHE
    now = time.time()
    if _PACKAGE_ROOT_CACHE is not None and now - _PACKAGE_ROOT_CACHE[0] < _SCRAPE_TTL_SEC:
        return _PACKAGE_ROOT_CACHE[1]

    candidates = []
    # npm root -g
    try:
        import subprocess

        root = subprocess.check_output(
            ["npm", "root", "-g"], stderr=subprocess.DEVNULL, text=True, timeout=3
        ).strip()
        if root:
            candidates.append(Path(root) / "9router")
    except Exception:
        pass
    # which 9router → …/bin/9router → …/lib/node_modules/9router
    try:
        import shutil

        bin_path = shutil.which("9router")
        if bin_path:
            p = Path(bin_path).resolve()
            for parent in p.parents:
                hit = parent / "lib" / "node_modules" / "9router"
                if hit.is_dir():
                    candidates.append(hit)
                hit2 = parent / "node_modules" / "9router"
                if hit2.is_dir():
                    candidates.append(hit2)
    except Exception:
        pass
    nvm = home() / ".nvm" / "versions" / "node"
    if nvm.is_dir():
        for ver in sorted(nvm.iterdir(), reverse=True):
            candidates.append(ver / "lib" / "node_modules" / "9router")

    seen = set()
    for c in candidates:
        try:
            c = c.resolve()
        except Exception:
            continue
        if c in seen or not c.is_dir():
            continue
        seen.add(c)
        if (c / "package.json").exists():
            _PACKAGE_ROOT_CACHE = (now, c)
            return c
    _PACKAGE_ROOT_CACHE = (now, None)
    return None


_ALIAS_CACHE: tuple[float, dict] | None = None
_REGISTRY_CACHE: tuple[float, dict] | None = None
_PACKAGE_ROOT_CACHE: tuple[float, Optional[Path]] | None = None
_SCRAPE_TTL_SEC = 300.0  # registry/alias ít đổi — tránh rglob mỗi lần health


def _cache_dir() -> Path:
    d = home() / "ai-stack" / "cursor-bridge"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _load_disk_cache(name: str) -> Optional[dict]:
    path = _cache_dir() / name
    try:
        if not path.exists():
            return None
        if time.time() - path.stat().st_mtime > _SCRAPE_TTL_SEC:
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def _save_disk_cache(name: str, data: dict) -> None:
    path = _cache_dir() / name
    try:
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass


def load_provider_alias_map() -> dict:
    """
    Build alias↔providerId map from the *installed* 9Router registry + user DB.
    Not a hardcoded product list — discovered from this machine's 9router install
    and providerNodes prefixes in ~/.9router/db.
    """
    global _ALIAS_CACHE
    now = time.time()
    if _ALIAS_CACHE is not None and now - _ALIAS_CACHE[0] < _SCRAPE_TTL_SEC:
        return _ALIAS_CACHE[1]
    disk = _load_disk_cache("alias-map-cache.json")
    if disk is not None:
        _ALIAS_CACHE = (now, disk)
        return disk

    mapping = {}

    root = find_9router_package_root()
    if root is not None:
        import re

        pattern = re.compile(
            r'\{id:"([^"]+)",(?=[^}]{0,800}?alias:"([^"]+)")[^}]*\}'
        )
        chunk_files = []
        for p in root.rglob("*.js"):
            if ".next-cli-build" not in p.parts:
                continue
            try:
                if p.stat().st_size < 50_000:
                    continue
            except Exception:
                continue
            chunk_files.append(p)
        for p in sorted(chunk_files, key=lambda x: x.stat().st_size, reverse=True)[:40]:
            try:
                text = p.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            if 'alias:"cu"' not in text and 'id:"cursor"' not in text:
                continue
            for pid, alias in pattern.findall(text):
                if not pid or not alias:
                    continue
                mapping[alias] = pid
                mapping[pid] = pid
            if "cu" in mapping and mapping.get("cu") == "cursor":
                break

    db = home() / ".9router" / "db" / "data.sqlite"
    if db.exists():
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            rows = con.execute("SELECT id, data FROM providerNodes").fetchall()
            con.close()
            for nid, raw in rows:
                try:
                    data = json.loads(raw or "{}")
                except Exception:
                    data = {}
                prefix = str(data.get("prefix") or "").strip()
                if prefix:
                    mapping[prefix] = str(nid)
                    mapping[str(nid)] = str(nid)
        except Exception:
            pass

    _ALIAS_CACHE = (now, mapping)
    _save_disk_cache("alias-map-cache.json", mapping)
    return mapping


def load_provider_node_names(con) -> dict:
    """id → display name from providerNodes table."""
    out = {}
    try:
        rows = con.execute("SELECT id, data FROM providerNodes").fetchall()
        for nid, raw in rows:
            try:
                data = json.loads(raw or "{}")
            except Exception:
                data = {}
            name = str(data.get("name") or "").strip()
            pid = str(nid or "").strip()
            if pid and name:
                out[pid] = name
    except Exception:
        pass
    return out


def load_provider_registry() -> dict:
    """
    id → {name, alias, noAuth, llm} từ registry 9Router đã cài.
    Dùng đúng rule Topology Usage: label + noAuth extras.
    """
    global _REGISTRY_CACHE
    now = time.time()
    if _REGISTRY_CACHE is not None and now - _REGISTRY_CACHE[0] < _SCRAPE_TTL_SEC:
        return _REGISTRY_CACHE[1]
    disk = _load_disk_cache("provider-registry-cache.json")
    if disk is not None:
        _REGISTRY_CACHE = (now, disk)
        return disk

    import re

    out: dict[str, dict] = {}
    root = find_9router_package_root()
    if root is None:
        _REGISTRY_CACHE = (now, out)
        _save_disk_cache("provider-registry-cache.json", out)
        return out
    chunk_files = []
    for p in root.rglob("*.js"):
        if ".next-cli-build" not in p.parts:
            continue
        try:
            if p.stat().st_size < 80_000:
                continue
        except Exception:
            continue
        chunk_files.append(p)

    id_re = re.compile(r'\bid:"([^"]+)"')
    for p in sorted(chunk_files, key=lambda x: x.stat().st_size, reverse=True)[:20]:
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        if 'id:"cursor"' not in text:
            continue
        # Cửa sổ đủ lớn để bắt noAuth / display.name / serviceKinds sau id
        for m in id_re.finditer(text):
            pid = m.group(1)
            if "/" in pid and not pid.startswith("openai"):
                # model ids trong catalog — bỏ qua trừ khi cần
                if pid.count("/") >= 1 and len(pid) > 40:
                    continue
            block = text[m.start() : m.start() + 2500]
            disp = re.search(r'display:\{name:"([^"]+)"', block[:500])
            name = disp.group(1) if disp else None
            if not name:
                # name gần id (tránh hốt tên provider khác trong cửa sổ lớn)
                name_m = re.search(r'name:"([^"]+)"', text[m.start() : m.start() + 180])
                name = name_m.group(1) if name_m else None
            if not name:
                continue
            if " CLI" in name:
                name = name.split(" CLI", 1)[0].strip()
            alias_m = re.search(r'alias:"([^"]+)"', text[m.start() : m.start() + 120])
            sk_m = re.search(r'serviceKinds:\[([^\]]*)\]', block)
            kinds = re.findall(r'"([^"]+)"', sk_m.group(1)) if sk_m else []
            no_auth = "noAuth:!0" in block[:800] or "noAuth:true" in block[:800]
            is_llm = (not kinds) or ("llm" in kinds)
            head = text[m.start() : m.start() + 450]
            free_provider = bool(
                'alias:"' in head
                and 'category:"free"' in head
                and "noAuth:!0" in head
                and "/" not in pid
                and not re.search(r"\d", pid)
                and is_llm
            )
            prev = out.get(pid)
            if prev is None:
                out[pid] = {
                    "name": name,
                    "alias": alias_m.group(1) if alias_m else None,
                    "noAuth": no_auth,
                    "llm": is_llm,
                    "freeProvider": free_provider,
                }
            else:
                if disp:
                    prev["name"] = name  # display.name luôn thắng
                if no_auth:
                    prev["noAuth"] = True
                if free_provider:
                    prev["freeProvider"] = True
                    if alias_m:
                        prev["alias"] = alias_m.group(1)
                if alias_m and not prev.get("alias"):
                    prev["alias"] = alias_m.group(1)
                if kinds:
                    prev["llm"] = "llm" in kinds
                elif "llm" not in prev:
                    prev["llm"] = is_llm
        if out.get("mimo-free", {}).get("freeProvider") and out.get("opencode", {}).get("freeProvider"):
            break
    _REGISTRY_CACHE = (now, out)
    _save_disk_cache("provider-registry-cache.json", out)
    return out


def _connection_locked_model(c: dict) -> str:
    """Model đang gắn với connection: defaultModel hoặc modelLock_*."""
    dm = str(c.get("defaultModel") or "").strip()
    if dm:
        return dm
    locks = []
    for k in c:
        if not isinstance(k, str) or not k.startswith("modelLock_"):
            continue
        mid = k[len("modelLock_") :].strip()
        if mid:
            locks.append(mid)
    if not locks:
        return ""
    # Ưu tiên id có namespace (provider/model) rồi mới tới tên ngắn.
    locks.sort(key=lambda s: (0 if "/" in s else 1, len(s)))
    return locks[0]


def _connection_health(c: dict) -> tuple[str, bool, object, str]:
    """
    Health thật từ connection 9Router (không ép OK).
    Trả về (testStatus, usable, errorCode, lastError).
    """
    raw_status = str(c.get("testStatus") or "").strip()
    is_active = c.get("isActive") is not False
    status = raw_status or ("active" if is_active else "inactive")
    code = c.get("errorCode")
    try:
        code_i = int(code) if code is not None and str(code).lstrip("-").isdigit() else None
    except Exception:
        code_i = None
    err = _short_error(str(c.get("lastError") or "")[:400], code if code_i is None else code_i)
    spurious = _is_spurious_test_error(err, code_i)
    healthy = status in ("active", "ok", "ready")
    usable = healthy
    if status in ("unavailable", "error", "failed", "inactive"):
        if spurious and (is_active or healthy or not err):
            usable = False
            status = "stale"
            err = "Trạng thái cache lỗi test (max_tokens…) — bấm Làm mới để probe thật"
            code_i = None
        else:
            usable = False
    elif not healthy and code_i is not None and code_i >= 400:
        usable = False
    return status, usable, (code_i if code_i is not None else code), ("" if usable and healthy else err)


def usage_topology_providers() -> list[dict]:
    """
    Topology trang Usage 9Router:
      GET /api/providers + /api/provider-nodes
      + category free & noAuth LLM trong registry chưa có connection
      Connections từ API: LUÔN hiện (không filter llm scrape — scrape hay sai,
      khiến provider mới / cursor bị mất). Dedupe theo provider id.
      status/model lấy THẬT từ connection.
    """
    token = _mint_dashboard_jwt()
    connections: list = []
    node_names: dict = {}
    if token:
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

            def _get(url: str):
                req = urllib.request.Request(
                    url,
                    headers={
                        "Cookie": f"auth_token={token}",
                        "User-Agent": "AI-Gate-Health/1.0",
                    },
                )
                with opener.open(req, timeout=4) as resp:
                    return json.loads(resp.read().decode("utf-8", "replace"))

            connections = (_get("http://127.0.0.1:20128/api/providers") or {}).get("connections") or []
            nodes = (_get("http://127.0.0.1:20128/api/provider-nodes") or {}).get("nodes") or []
            for n in nodes:
                nid = str(n.get("id") or "")
                nm = str(n.get("name") or "").strip()
                if nid and nm:
                    node_names[nid] = nm
        except Exception:
            connections = []

    # Fallback SQLite nếu API fail — cần kèm data JSON (testStatus/modelLock/…)
    if not connections:
        db = home() / ".9router" / "db" / "data.sqlite"
        if db.exists():
            try:
                con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
                con.row_factory = sqlite3.Row
                rows = con.execute(
                    "SELECT id, provider, name, isActive, data FROM providerConnections"
                ).fetchall()
                node_names = load_provider_node_names(con)
                con.close()
                connections = []
                for r in rows:
                    try:
                        data = json.loads(r["data"] or "{}")
                    except Exception:
                        data = {}
                    if not isinstance(data, dict):
                        data = {}
                    item = dict(data)
                    item.update(
                        {
                            "id": r["id"],
                            "provider": r["provider"],
                            "name": r["name"] or data.get("name") or "",
                            "isActive": bool(r["isActive"]),
                        }
                    )
                    connections.append(item)
            except Exception:
                connections = []

    registry = load_provider_registry()
    seen: set[str] = set()
    out: list[dict] = []

    def label_for(pid: str, node_name, conn_name):
        g = registry.get(pid) or {}
        reg_name = str(g.get("name") or "").strip()
        # 9Router: (g.name !== provider ? g.name : null) || nodeName || name || provider
        if reg_name and reg_name != pid:
            return reg_name
        if node_name:
            return node_name
        if conn_name and "@" not in conn_name and "|" not in conn_name:
            return conn_name
        return pid

    # Nhiều connection cùng provider → chọn connection "khỏe" nhất (active > stale > lỗi).
    best_by_pid: dict[str, dict] = {}

    def _rank(c: dict) -> tuple:
        status, usable, _, _ = _connection_health(c)
        return (
            1 if c.get("isActive") is not False else 0,
            1 if usable else 0,
            1 if status in ("active", "ok", "ready") else 0,
            0 if status == "stale" else 1,
            1 if _connection_locked_model(c) else 0,
        )

    for c in connections:
        # Giống 9Router Usage: bỏ connection tắt (isActive === false).
        if c.get("isActive") is False:
            continue
        pid = str(c.get("provider") or "").strip()
        if not pid:
            continue
        # KHÔNG filter llm từ registry scrape — connection thật luôn được hiện
        # (scrape hay gán llm=False nhầm → mất cursor / provider mới).
        prev = best_by_pid.get(pid)
        if prev is None or _rank(c) > _rank(prev):
            best_by_pid[pid] = c

    for pid, c in best_by_pid.items():
        seen.add(pid)
        nn = node_names.get(pid) or c.get("nodeName")
        locked = _connection_locked_model(c)
        status, usable, code, err = _connection_health(c)
        # isActive=false đã loại; nếu còn thì active=True
        is_on = c.get("isActive") is not False
        if not is_on:
            status, usable, code, err = "inactive", False, None, ""
        out.append(
            {
                "model": locked if locked else pid,
                "provider": pid,
                "name": str(c.get("name") or ""),
                "displayName": label_for(pid, nn, str(c.get("name") or "")),
                "active": is_on,
                "testStatus": status,
                "errorCode": code,
                "lastError": err,
                "usable": usable if is_on else False,
                "live": False,
                "source": "connection",
                "connectionId": str(c.get("id") or ""),
            }
        )

    # 9Router IS = category "free"; topology thêm free & noAuth & llm chưa có connection.
    for pid, g in registry.items():
        if not g.get("freeProvider"):
            continue
        if not g.get("noAuth"):
            continue
        if pid in seen or "/" in pid:
            continue
        seen.add(pid)
        out.append(
            {
                "model": pid,
                "provider": pid,
                "name": "",
                "displayName": label_for(pid, node_names.get(pid), None),
                "active": True,
                "testStatus": "active",
                "errorCode": None,
                "lastError": "",
                "usable": True,
                "live": False,
                "source": "noAuth",
            }
        )

    return out


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
        node_names = load_provider_node_names(con)
        con.close()
    except Exception:
        return []

    alias_map = load_provider_alias_map()
    by_key = {}

    def add_key(key, item):
        key = str(key or "").strip()
        if not key:
            return
        by_key.setdefault(key, []).append(item)

    parsed_rows = []
    for r in rows:
        try:
            data = json.loads(r["data"] or "{}")
        except Exception:
            data = {}
        item = (r, data)
        parsed_rows.append(item)
        pid = str(r["provider"] or "")
        add_key(pid, item)
        prefix = (data.get("providerSpecificData") or {}).get("prefix")
        if prefix:
            add_key(str(prefix).split("/")[0], item)
        for alias, canon in alias_map.items():
            if canon == pid or alias == pid:
                add_key(alias, item)
                add_key(canon, item)

    def display_for(provider_id: str, prefix: str) -> str:
        pid = str(provider_id or "").strip()
        pref = str(prefix or "").strip()
        if pid and pid in node_names:
            return node_names[pid]
        # alias → canonical id → node name
        canon = alias_map.get(pref) or alias_map.get(pid) or ""
        if canon and canon in node_names:
            return node_names[canon]
        # Provider built-in id (antigravity, tokenrouter, openrouter…)
        if pid and not pid.startswith("openai-compatible") and "@" not in pid and "|" not in pid:
            return pid
        if canon and not str(canon).startswith("openai-compatible"):
            return str(canon)
        if pref and not pref.startswith("openai-compatible"):
            return pref
        return pid or pref

    out_list = []
    for mid in combo_models:
        prefix = mid.split("/", 1)[0]
        model_name = mid.split("/", 1)[1] if "/" in mid else mid
        resolved = alias_map.get(prefix, prefix)
        matches = list(by_key.get(prefix) or [])
        if resolved != prefix:
            for item in by_key.get(resolved) or []:
                if item not in matches:
                    matches.append(item)

        if not matches:
            for r, data in parsed_rows:
                locks = [k for k in data if k.startswith("modelLock_")]
                default = str(data.get("defaultModel") or "")
                if any(model_name and (model_name in k or k.endswith(model_name)) for k in locks):
                    matches.append((r, data))
                elif default in (model_name, mid) or default.endswith("/" + model_name):
                    matches.append((r, data))

        best = None
        for r, data in matches:
            locks = {k: v for k, v in data.items() if k.startswith("modelLock_")}
            score = 0
            if any(model_name in k or k.endswith(model_name) for k in locks):
                score = 2
            elif data.get("defaultModel") in (model_name, mid) or str(
                data.get("defaultModel") or ""
            ).endswith("/" + model_name):
                score = 1
            if best is None or score > best[0]:
                best = (score, r, data, locks)
        if not best:
            out_list.append(
                {
                    "model": mid,
                    "provider": resolved if resolved else prefix,
                    "name": "",
                    "displayName": display_for(resolved, prefix),
                    "active": False,
                    "testStatus": "unknown",
                    "errorCode": None,
                    "lastError": "No matching provider connection",
                    "usable": False,
                }
            )
            continue
        _, r, data, locks = best
        err = _short_error((data.get("lastError") or "")[:400], data.get("errorCode"))
        code = data.get("errorCode")
        try:
            code_i = int(code) if code is not None and str(code).lstrip("-").isdigit() else None
        except Exception:
            code_i = None
        status = (data.get("testStatus") or "").strip() or (
            "active" if r["isActive"] else "inactive"
        )
        spurious = _is_spurious_test_error(err, code_i)
        # testStatus phản ánh health; isActive=0 (vd. cursor) vẫn có thể serve request.
        healthy = status in ("active", "ok", "ready")
        usable = healthy
        if status in ("unavailable", "error", "failed", "inactive"):
            if spurious and (bool(r["isActive"]) or healthy or not err):
                usable = False
                status = "stale"
                err = "Trạng thái cache lỗi test (max_tokens…) — bấm Làm mới để probe thật"
                code_i = None
            else:
                usable = False
        elif not healthy and code_i is not None and code_i >= 400:
            usable = False
        if (
            status in ("unavailable", "error", "failed")
            and err
            and not spurious
            and any(
                tok in err.lower()
                for tok in (
                    "model_not_found",
                    "activity_cost",
                    "no available channel",
                    "temporarily unavailable",
                )
            )
        ):
            usable = False
        # Không có connection match thật sự
        if status == "unknown" and "No matching" in (err or ""):
            usable = False
        pid = str(r["provider"] or "")
        out_list.append(
            {
                "model": mid,
                "provider": pid,
                "name": r["name"] or "",
                "displayName": display_for(pid, prefix),
                "active": bool(r["isActive"]),
                "testStatus": status,
                "errorCode": code_i if code_i is not None else code,
                "lastError": err if not usable else ("" if healthy else err),
                "usable": usable,
                "live": False,
            }
        )
    return out_list


def _is_spurious_test_error(err: str, code) -> bool:
    e = (err or "").lower()
    return "max_tokens" in e or "must be greater than" in e


def _short_error(text: str, code=None) -> str:
    import re

    raw = (text or "").strip()
    if not raw:
        return f"[{code}]" if code else ""

    def extract_msg(blob: str) -> str:
        if not blob:
            return ""
        payload = blob[blob.index("{") :] if "{" in blob else blob
        try:
            err_obj = json.loads(payload)
            if isinstance(err_obj, dict):
                err = err_obj.get("error")
                if isinstance(err, dict):
                    m = str(err.get("message") or err.get("code") or "")
                    if m:
                        return m
                elif isinstance(err, str) and err:
                    return err
                m = str(err_obj.get("message") or err_obj.get("detail") or "")
                if m:
                    return m
        except Exception:
            pass
        m = re.search(r'"(?:message|detail)"\s*:\s*"((?:\\.|[^"\\])*)"', blob)
        if m:
            try:
                return json.loads(f'"{m.group(1)}"')
            except Exception:
                return m.group(1)
        # Truncated JSON — lấy đến hết chuỗi còn lại
        m = re.search(r'"(?:message|detail)"\s*:\s*"((?:\\.|[^"\\])*)', blob)
        if m:
            return m.group(1)
        return ""

    msg = extract_msg(raw)
    # 9Router hay bọc lỗi dạng [provider/model] [400]: {json}
    if msg and ("{" in msg or msg.strip().startswith("[")):
        inner = extract_msg(msg)
        if inner:
            msg = inner
        else:
            msg = re.sub(r"^\[[^\]]+\]\s*", "", msg).strip()
            if "{" in msg:
                inner = extract_msg(msg)
                if inner:
                    msg = inner

    if msg:
        msg = re.sub(r"^\[[^\]]+\]\s*", "", str(msg)).strip() or str(msg)
        # Tránh "[503] [503] …"
        msg = re.sub(r"^\[\d+\]\s*", "", msg).strip() or msg
        return (f"[{code}] {msg}" if code is not None else msg)[:200]

    compact = re.sub(r"\s+", " ", raw)
    compact = re.sub(r"^\[[^\]]+\]\s*", "", compact).strip() or compact
    if code is not None:
        compact = re.sub(r"^\[\d+\]\s*:?\s*", "", compact).strip() or compact
        return f"[{code}] {compact}"[:200]
    return compact[:200]


def live_probe_topology(providers: list[dict], auth_token: str, api_key: str) -> list[dict]:
    """
    Live đúng connection 9Router: POST /api/providers/{connectionId}/test
    (chat /v1 theo model hay ra 404 giả vì route nhầm provider prefix).
    Free/noAuth không có connectionId → fallback chat ping model=provider.
    """
    if not providers:
        return providers

    from concurrent.futures import ThreadPoolExecutor, as_completed

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def probe_connection(item: dict) -> dict:
        cid = str(item.get("connectionId") or "").strip()
        item = dict(item)
        item["live"] = True
        if not cid:
            # free/noAuth: chat /v1 hay 404 giả — không kết luận fail.
            item["live"] = True
            item["usable"] = True
            item["testStatus"] = "active"
            item["errorCode"] = None
            item["lastError"] = ""
            return item

        t0 = time.time()
        req = urllib.request.Request(
            f"http://127.0.0.1:20128/api/providers/{cid}/test",
            data=b"{}",
            method="POST",
            headers={
                "Cookie": f"auth_token={auth_token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "AI-Gate-Health/1.0",
            },
        )
        try:
            with opener.open(req, timeout=20.0) as resp:
                raw = resp.read(4000)
                ms = int((time.time() - t0) * 1000)
                obj = json.loads(raw.decode("utf-8", "replace") or "{}")
                valid = bool(obj.get("valid"))
                err = str(obj.get("error") or "").strip()
                item["latencyMs"] = ms
                item["live"] = True
                if valid:
                    item["usable"] = True
                    item["testStatus"] = "active"
                    item["errorCode"] = None
                    item["lastError"] = ""
                elif "not supported" in err.lower():
                    # API không hỗ trợ test — không đánh Fail giả.
                    item["testStatus"] = "unknown"
                    item["errorCode"] = None
                    item["lastError"] = ""
                    # giữ usable cũ (thường từ cache); nếu chưa có thì N/A
                else:
                    item["usable"] = False
                    item["testStatus"] = "unavailable"
                    sc = obj.get("statusCode")
                    item["errorCode"] = sc if isinstance(sc, int) else None
                    item["lastError"] = err[:200] if err else "Connection test failed"
                return item
        except urllib.error.HTTPError as e:
            ms = int((time.time() - t0) * 1000)
            text = e.read(800).decode("utf-8", "replace") if hasattr(e, "read") else str(e)
            item["latencyMs"] = ms
            item["usable"] = False
            item["testStatus"] = "unavailable"
            item["errorCode"] = int(e.code)
            item["lastError"] = _short_error(text, e.code)
            return item
        except Exception as e:
            item["latencyMs"] = int((time.time() - t0) * 1000)
            item["usable"] = False
            item["testStatus"] = "error"
            item["errorCode"] = None
            item["lastError"] = str(e)[:200]
            return item

    with ThreadPoolExecutor(max_workers=6) as pool:
        futs = {pool.submit(probe_connection, dict(p)): i for i, p in enumerate(providers)}
        results = [None] * len(providers)
        for fut in as_completed(futs):
            idx = futs[fut]
            try:
                results[idx] = fut.result()
            except Exception as e:
                base = dict(providers[idx])
                base["live"] = True
                base["usable"] = False
                base["lastError"] = str(e)[:200]
                results[idx] = base
        return [r for r in results if r is not None]


def live_probe_providers(providers: list[dict], api_key: str) -> list[dict]:
    """Probe thật từng model qua /v1/chat/completions (max_tokens đủ lớn)."""
    if not providers:
        return providers
    if not api_key:
        for p in providers:
            p["lastError"] = "Thiếu API key 9Router — không probe được"
            p["usable"] = False
            p["live"] = False
        return providers

    from concurrent.futures import ThreadPoolExecutor, as_completed

    def probe_one(item: dict) -> dict:
        mid = item.get("model") or ""
        if item.get("lastError") == "No matching provider connection" and not item.get("active"):
            item["live"] = True
            return item
        body = json.dumps(
            {
                "model": mid,
                "messages": [{"role": "user", "content": "ping"}],
                "max_tokens": 16,
            }
        ).encode("utf-8")
        req = urllib.request.Request(
            "http://127.0.0.1:20128/v1/chat/completions",
            data=body,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "User-Agent": "AI-Gate-Health/1.0",
            },
            method="POST",
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        t0 = time.time()
        try:
            with opener.open(req, timeout=8.0) as resp:
                raw = resp.read(800)
                ms = int((time.time() - t0) * 1000)
                code = getattr(resp, "status", 200)
                item["live"] = True
                item["latencyMs"] = ms
                item["errorCode"] = code if code >= 400 else None
                item["testStatus"] = "active" if 200 <= code < 300 else "unavailable"
                item["usable"] = 200 <= code < 300
                item["lastError"] = "" if item["usable"] else _short_error(raw.decode("utf-8", errors="replace"), code)
                return item
        except urllib.error.HTTPError as e:
            ms = int((time.time() - t0) * 1000)
            raw = e.read(800) if hasattr(e, "read") else b""
            text = raw.decode("utf-8", errors="replace") if raw else str(e)
            item["live"] = True
            item["latencyMs"] = ms
            item["errorCode"] = int(e.code)
            item["testStatus"] = "unavailable"
            item["usable"] = False
            item["lastError"] = _short_error(text, e.code)
            return item
        except Exception as e:
            item["live"] = True
            item["latencyMs"] = int((time.time() - t0) * 1000)
            item["errorCode"] = None
            item["testStatus"] = "error"
            item["usable"] = False
            item["lastError"] = str(e)[:200]
            return item

    updated = []
    with ThreadPoolExecutor(max_workers=5) as pool:
        futs = {pool.submit(probe_one, dict(p)): i for i, p in enumerate(providers)}
        results = [None] * len(providers)
        for fut in as_completed(futs):
            idx = futs[fut]
            try:
                results[idx] = fut.result()
            except Exception as e:
                base = dict(providers[idx])
                base["live"] = True
                base["usable"] = False
                base["lastError"] = str(e)[:200]
                results[idx] = base
        updated = [r for r in results if r is not None]
    return updated


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
        applied = ""
        for cand in moe + uam:
            if cand == model:
                applied = cand
                break
        if not applied:
            for cand in moe + uam:
                if cand:
                    applied = cand
                    break
        exp = (expected_base or "").rstrip("/")
        base_ok = bool(exp) and base == exp
        has_secret = bool(sec and sec[0] and sec[0] > 10) or bool(plain and plain[0] and plain[0] > 0)
        # Cấu hình Cursor OK khi Base URL + key + đã có ít nhất 1 model apply — không phụ thuộc combo đang xem.
        configured = base_ok and use_key and bool(applied) and has_secret
        msg = "Cursor khớp Bridge"
        if not base_ok:
            msg = "Base URL Cursor lệch hoặc trống"
        elif not use_key:
            msg = "OpenAI API Key chưa bật trong Cursor"
        elif not applied:
            msg = "Cursor chưa có model/combo"
        elif not has_secret:
            msg = "Thiếu API key trong Cursor"
        elif not has_model:
            msg = f"Combo đang xem «{model}» khác combo Cursor «{applied}»"
        return {
            "configured": configured,
            "hasDb": True,
            "baseUrl": base,
            "useOpenAIKey": use_key,
            "hasModel": has_model,
            "hasKey": has_secret,
            "appliedModel": applied,
            "message": msg,
        }
    except Exception as e:
        return {
            "configured": False,
            "hasDb": True,
            "message": f"Đọc Cursor DB lỗi: {e}"[:160],
        }


def read_codex_model() -> str:
    path = home() / ".codex" / "config.toml"
    if not path.exists():
        return ""
    try:
        import re

        text = path.read_text(encoding="utf-8")
        m = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"\s*$', text)
        if m:
            return m.group(1).strip()
        m = re.search(r"(?m)^\s*model\s*=\s*'([^']+)'\s*$", text)
        return m.group(1).strip() if m else ""
    except Exception:
        return ""


def main() -> int:
    # Topology-only: cùng nguồn Usage 9Router, nhẹ — dùng cho poll UI.
    if "--topology" in sys.argv:
        items = usage_topology_providers()
        active = sum(1 for p in items if p.get("usable"))
        print(
            json.dumps(
                {
                    "topologyProviders": items,
                    "topologyActive": active,
                    "topologyCount": len(items),
                },
                ensure_ascii=False,
            )
        )
        return 0

    model_arg = "my-combo"
    live = False
    silent = False
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        model_arg = sys.argv[1]
    for i, a in enumerate(sys.argv):
        if a == "--model" and i + 1 < len(sys.argv):
            model_arg = sys.argv[i + 1]
        if a == "--live":
            live = True
        if a == "--silent":
            silent = True

    bridge = load_bridge()
    base = str(bridge.get("baseUrl") or "").rstrip("/")
    funnel_cli = bool(bridge.get("funnelEnabled"))
    wanted = bool(bridge.get("wanted"))

    local_dash = http_probe("http://127.0.0.1:20128/dashboard", timeout=2.5)
    local_router = local_dash.get("ok") and local_dash.get("status", 0) in (200, 301, 302, 303, 307, 308)

    key = read_api_key()
    # Silent: dashboard OK là đủ cho local — /v1/models có thể rất chậm/nặng.
    if silent and not live and local_router:
        local_api = {"ok": True, "status": 200, "ms": local_dash.get("ms", 0)}
        local_api_ok = True
    else:
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
    # Silent + bridge tắt: bỏ probe public (tiết kiệm network). Khi wanted vẫn cần.
    if base and (wanted or not silent):
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
    if live and local_router:
        providers = live_probe_providers(providers, key)
    usable_count = sum(1 for p in providers if p.get("usable"))
    combo_healthy = usable_count > 0 if providers else False

    # Topology: silent poll bỏ qua (UI giữ qua HTTP sync) — tránh rglob registry.
    if silent and not live:
        topology = []
        topology_active = 0
    else:
        topology = usage_topology_providers() if local_router else []
        # Nút Topology (--live): test đúng connection API 9Router (không chat-ping model → 404 giả).
        if live and local_router and topology:
            auth = _mint_dashboard_jwt() or ""
            topology = live_probe_topology(topology, auth, key)
        # Chỉ đếm provider thật sự usable — không cộng connection lỗi / inactive.
        topology_active = sum(1 for p in topology if p.get("usable"))

    expected_cursor_base = expected_cursor_base_url() or base
    cursor = cursor_config_match(expected_cursor_base, model_arg)

    cursor_base = str(cursor.get("baseUrl") or "").rstrip("/")
    cursor_uses_localhost = bool(
        cursor_base
        and ("127.0.0.1" in cursor_base or "localhost" in cursor_base)
    )
    cursor_uses_public = bool(
        cursor_base
        and not cursor_uses_localhost
        and cursor_base.startswith("https://")
    )
    public_up = bool(funnel_cli and public_reachable)
    # Cursor cloud cannot call localhost — stale/wrong when local or Funnel down.
    cursor_stale_public = (cursor_uses_public and not public_up) or cursor_uses_localhost
    shim_running = _port_listening(20129)

    if wanted:
        cursor_path_ok = (
            funnel_cli
            and public_reachable
            and shim_running
            and cursor.get("configured", False)
            and not cursor_stale_public
            and (combo_healthy or not providers)
        )
    else:
        cursor_path_ok = not cursor_stale_public


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
        "expectedCursorBaseUrl": expected_cursor_base,
        "cursorShimRunning": shim_running,
        "cursorAppliedModel": str(cursor.get("appliedModel") or ""),
        "codexAppliedModel": read_codex_model(),
        "comboName": combo_name,
        "comboHealthy": combo_healthy,
        "usableProviders": usable_count,
        "providerCount": len(providers),
        "providers": providers,
        "topologyProviders": topology,
        "topologyActive": topology_active,
        "topologyCount": len(topology),
        "liveProbed": bool(live),
        "cursorPathOk": bool(cursor_path_ok),
        "cursorStalePublic": bool(cursor_stale_public),
        "message": _summary_message(
            local_router,
            local_api_ok,
            wanted,
            funnel_cli,
            bool(public_reachable) if base else False,
            cursor.get("configured", False),
            combo_healthy,
            providers,
            cursor_stale_public=cursor_stale_public,
        ),
    }
    if live:
        result["message"] = (
            f"Đã probe live Topology: {topology_active}/{len(topology)} provider OK"
            if topology
            else f"Đã probe live combo: {usable_count}/{len(providers)} model OK"
        )
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
    cursor_stale_public: bool = False,
) -> str:
    if not local_router:
        return "9Router local chưa sẵn sàng"
    if not local_api:
        return "Local API /v1 chậm hoặc không trả lời (Codex có thể vẫn dùng được dashboard)"
    if cursor_stale_public and cursor_uses_localhost:
        return "Cursor đang trỏ localhost — Cursor cloud không gọi được. Bấm Apply để dùng Funnel https://….ts.net/v1"
    if cursor_stale_public:
        return "Cursor trỏ Funnel URL nhưng tunnel chưa tới được → Network Error. Bật lại «Dùng với Cursor»"
    if not wanted:
        return "Local OK • Cursor Bridge chưa bật"
    if not funnel_cli:
        return "Funnel CLI đang tắt — Cursor không vào được"
    if not public_reachable:
        return "Funnel public không tới được (Cursor sẽ Network Error; Codex local vẫn OK)"
    if not _port_listening(20129):
        return "Cursor Responses shim (:20129) chưa chạy — Funnel phải trỏ shim, không trỏ thẳng :20128"
    if not cursor_configured:
        return "Funnel OK nhưng Cursor chưa Apply đúng Base URL/key/model"
    if providers and not combo_healthy:
        return "Cursor path OK nhưng combo không còn provider usable"
    return "Cursor path sẵn sàng — chọn model combo trong Cursor (Ask + Agent)"


if __name__ == "__main__":
    sys.exit(main())
