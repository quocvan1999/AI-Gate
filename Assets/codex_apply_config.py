#!/usr/bin/env python3
"""Apply / read Codex model (combo) in ~/.codex/config.toml — only the model line."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def out(ok: bool, **extra) -> int:
    print(json.dumps({"ok": ok, **extra}, ensure_ascii=False))
    return 0 if ok else 1


def config_path() -> Path:
    return Path.home() / ".codex" / "config.toml"


def read_model() -> str:
    path = config_path()
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


def apply_model(model: str) -> int:
    model = (model or "").strip()
    if not model:
        return out(False, message="Thiếu model/combo", model="")
    path = config_path()
    if not path.exists():
        return out(False, message=f"Không thấy {path}", model=model)

    try:
        text = path.read_text(encoding="utf-8")
    except Exception as e:
        return out(False, message=f"Đọc config.toml lỗi: {e}", model=model)

    pattern = re.compile(r'(?m)^(\s*model\s*=\s*)(["\'])([^"\']*)\2(\s*)$')
    if pattern.search(text):
        new_text, n = pattern.subn(rf'\1"{model}"\4', text, count=1)
        if n != 1:
            return out(False, message="Không thay được dòng model", model=model)
    else:
        # Insert near top after optional comments
        new_text = f'model = "{model}"\n' + text

    try:
        legacy = path.with_suffix(path.suffix + ".bak-aigate")
        try:
            legacy.unlink(missing_ok=True)
        except OSError:
            pass
        path.write_text(new_text, encoding="utf-8")
    except Exception as e:
        return out(False, message=f"Ghi config.toml lỗi: {e}", model=model)

    return out(
        True,
        message=f"Đã áp dụng combo «{model}» vào Codex",
        model=model,
        path=str(path),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply combo into Codex config.toml")
    parser.add_argument("--model", default="")
    parser.add_argument("--read", action="store_true")
    args = parser.parse_args()
    if args.read:
        return out(True, model=read_model(), path=str(config_path()))
    return apply_model(args.model)


if __name__ == "__main__":
    sys.exit(main())
