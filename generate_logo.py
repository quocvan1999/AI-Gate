#!/usr/bin/env python3
"""Export AppIcon from logoapp.png and NavIcon from logonav.png."""

import os
import shutil
import subprocess
import tempfile
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(ROOT, "Assets")
APP_SRC = os.path.join(ASSETS, "logo", "logoapp.png")
NAV_SRC = os.path.join(ASSETS, "logo", "logonav.png")


def resize(src: Image.Image, size: int) -> Image.Image:
    return src.resize((size, size), Image.Resampling.LANCZOS)


def write_icns(app_icon: Image.Image, outpath: str) -> None:
    iconset = tempfile.mkdtemp(suffix=".iconset")
    try:
        os.makedirs(iconset, exist_ok=True)
        for px, fn in [
            (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]:
            resize(app_icon, px).save(os.path.join(iconset, fn), "PNG")
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", outpath], check=True)
    finally:
        shutil.rmtree(iconset)


def main() -> None:
    app = resize(Image.open(APP_SRC).convert("RGBA"), 1024)
    nav = resize(Image.open(NAV_SRC).convert("RGBA"), 256)
    app.save(os.path.join(ASSETS, "AppIcon.png"), "PNG")
    nav.save(os.path.join(ASSETS, "NavIcon.png"), "PNG")
    write_icns(app, os.path.join(ASSETS, "AppIcon.icns"))
    print("OK: AppIcon <- logoapp.png, NavIcon <- logonav.png")


if __name__ == "__main__":
    main()
