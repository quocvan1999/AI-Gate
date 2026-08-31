#!/usr/bin/env python3
"""Export/import AI Gate configuration bundles (.aigate zip)."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import sqlite3
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

FORMAT_ID = "aigate-backup"
FORMAT_VERSION = 1


def out(ok: bool, **extra: Any) -> int:
    payload = {"ok": ok, **extra}
    print(json.dumps(payload, ensure_ascii=False))
    return 0 if ok else 1


def home() -> Path:
    return Path.home()


def app_support_dir() -> Path:
    path = home() / "Library" / "Application Support" / "AI Stack"
    path.mkdir(parents=True, exist_ok=True)
    return path


def nine_router_dir() -> Path:
    return home() / ".9router"


def bridge_desired_path() -> Path:
    return home() / "ai-stack" / "cursor-bridge" / "desired.json"


def codex_config_path() -> Path:
    return home() / ".codex" / "config.toml"


def proxies_path() -> Path:
    return app_support_dir() / "proxies.json"


def cursor_bridge_prefs_path() -> Path:
    return app_support_dir() / "cursor-bridge.json"


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def load_combos() -> dict[str, str]:
    prefs = read_json(cursor_bridge_prefs_path())
    return {
        "preview": str(prefs.get("previewCombo") or prefs.get("selectedModel") or "my-combo"),
        "cursor": str(prefs.get("cursorCombo") or prefs.get("previewCombo") or "my-combo"),
        "codex": str(prefs.get("codexCombo") or prefs.get("previewCombo") or "my-combo"),
    }


def backup_sqlite(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not src.exists():
        return
    src_con = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    dst_con = sqlite3.connect(dst)
    try:
        src_con.backup(dst_con)
    finally:
        dst_con.close()
        src_con.close()


SKIP_PARTS = {".DS_Store", "__pycache__"}
SKIP_DIR_NAMES = {"node_modules", ".git", "cache", "logs"}


def should_skip_nine_router_rel(rel: str) -> bool:
    parts = Path(rel).parts
    if not parts:
        return False
    if parts[0] in SKIP_DIR_NAMES or "node_modules" in parts:
        return True
    return rel.endswith(tuple(SKIP_PARTS))


def export_nine_router(staging: Path) -> list[str]:
    src = nine_router_dir()
    dst = staging / "nine_router"
    copied: list[str] = []
    if not src.exists():
        return copied

    db = src / "db" / "data.sqlite"
    if db.exists():
        backup_sqlite(db, dst / "db" / "data.sqlite")
        copied.append("nine_router/db/data.sqlite")

    for root, dirs, files in os.walk(src):
        rel_root = Path(root).relative_to(src)
        dirs[:] = [d for d in dirs if d not in SKIP_DIR_NAMES]
        if rel_root.parts and should_skip_nine_router_rel(rel_root.as_posix()):
            continue
        for name in files:
            if name in SKIP_PARTS:
                continue
            rel = (rel_root / name).as_posix()
            if rel == "db/data.sqlite" or should_skip_nine_router_rel(rel):
                continue
            target = dst / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src / rel, target)
            copied.append(f"nine_router/{rel}")
    return copied


def build_manifest(files: list[str]) -> dict[str, Any]:
    return {
        "format": FORMAT_ID,
        "version": FORMAT_VERSION,
        "created_at": now_iso(),
        "hostname": socket.gethostname(),
        "combos": load_combos(),
        "files": sorted(files),
    }


def create_staging_dir() -> tuple[Path, list[str]]:
    staging = Path(tempfile.mkdtemp(prefix="aigate-export-"))
    files: list[str] = []
    files.extend(export_nine_router(staging))

    mapping = [
        (proxies_path(), staging / "app_support" / "proxies.json", "app_support/proxies.json"),
        (cursor_bridge_prefs_path(), staging / "app_support" / "cursor-bridge.json", "app_support/cursor-bridge.json"),
        (bridge_desired_path(), staging / "cursor_bridge" / "desired.json", "cursor_bridge/desired.json"),
        (codex_config_path(), staging / "codex" / "config.toml", "codex/config.toml"),
    ]
    for src, dst, label in mapping:
        if src.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            files.append(label)
    return staging, files


def zip_dir(src_dir: Path, zip_path: Path) -> None:
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(src_dir):
            for name in files:
                full = Path(root) / name
                zf.write(full, arcname=full.relative_to(src_dir).as_posix())


def write_bundle(output: Path) -> dict[str, Any]:
    staging, files = create_staging_dir()
    manifest = build_manifest(files)
    write_json(staging / "manifest.json", manifest)

    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        zip_dir(staging, output)
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    return {
        "path": str(output),
        "manifest": manifest,
        "size_bytes": output.stat().st_size if output.exists() else 0,
    }


def extract_bundle(bundle: Path) -> tuple[Path, dict[str, Any]]:
    staging = Path(tempfile.mkdtemp(prefix="aigate-import-"))
    try:
        with zipfile.ZipFile(bundle, "r") as zf:
            zf.extractall(staging)
    except zipfile.BadZipFile as e:
        shutil.rmtree(staging, ignore_errors=True)
        raise RuntimeError("File không hợp lệ (không phải .aigate)") from e

    manifest_path = staging / "manifest.json"
    if not manifest_path.exists():
        shutil.rmtree(staging, ignore_errors=True)
        raise RuntimeError("Backup thiếu manifest.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("format") != FORMAT_ID:
        shutil.rmtree(staging, ignore_errors=True)
        raise RuntimeError("File không phải định dạng AI Gate backup")
    return staging, manifest


def restore_from_staging(staging: Path) -> dict[str, Any]:
    restored: list[str] = []

    nine_src = staging / "nine_router"
    if nine_src.exists():
        dst = nine_router_dir()
        db_src = nine_src / "db" / "data.sqlite"
        if db_src.exists():
            backup_sqlite(db_src, dst / "db" / "data.sqlite")
            restored.append("nine_router/db/data.sqlite")
        for root, _, files in os.walk(nine_src):
            for name in files:
                rel = (Path(root) / name).relative_to(nine_src)
                if rel.as_posix() == "db/data.sqlite":
                    continue
                target = dst / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(Path(root) / name, target)
                restored.append(f"nine_router/{rel.as_posix()}")

    mapping = [
        (staging / "app_support" / "proxies.json", proxies_path()),
        (staging / "app_support" / "cursor-bridge.json", cursor_bridge_prefs_path()),
        (staging / "cursor_bridge" / "desired.json", bridge_desired_path()),
        (staging / "codex" / "config.toml", codex_config_path()),
    ]
    for src, dst in mapping:
        if src.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            restored.append(dst.name)

    return {"restored": restored}


def cmd_export(args: argparse.Namespace) -> int:
    output = Path(args.output).expanduser()
    if not output.name.endswith(".aigate"):
        output = output.with_suffix(".aigate")
    try:
        info = write_bundle(output)
    except Exception as e:
        return out(False, message=str(e))
    return out(True, message=f"Đã tạo backup: {output.name}", **info)


def cmd_import(args: argparse.Namespace) -> int:
    bundle = Path(args.input).expanduser()
    if not bundle.exists():
        return out(False, message=f"Không thấy file: {bundle}")
    staging: Optional[Path] = None
    try:
        staging, manifest = extract_bundle(bundle)
        result = restore_from_staging(staging)
    except Exception as e:
        return out(False, message=str(e))
    finally:
        if staging:
            shutil.rmtree(staging, ignore_errors=True)
    return out(
        True,
        message="Đã restore cấu hình từ backup",
        manifest=manifest,
        combos=manifest.get("combos") or {},
        **result,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="AI Gate backup / restore")
    sub = parser.add_subparsers(dest="command", required=True)

    p_export = sub.add_parser("export")
    p_export.add_argument("--output", required=True)
    p_export.set_defaults(func=cmd_export)

    p_import = sub.add_parser("import")
    p_import.add_argument("--input", required=True)
    p_import.set_defaults(func=cmd_import)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
