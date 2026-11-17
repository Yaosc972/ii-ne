#!/usr/bin/env python3
"""从透明 logo 生成应用、菜单栏和 README 图标。

应用图标保留母图的构图与留白，使用浅米色背景。
菜单栏使用去除透明留白的单色模板，由系统适配明暗。

用法：
    python3 Tools/make-app-icon.py                      # 用仓库里的 Assets/logo-1024.png
    python3 Tools/make-app-icon.py <资源包目录>          # 直接读原始资源包
    python3 Tools/make-app-icon.py --preview <目录>
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

CANVAS = 1024
BACKDROP = (255, 247, 234, 255)

ICONSET_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

# 状态栏和菜单使用同一 logo 的剪影，颜色由系统决定。
STATUS_SIZES = [("StatusBarIcon.png", 18), ("StatusBarIcon@2x.png", 36)]
MENU_SIZES = [("MenuItemIcon.png", 16), ("MenuItemIcon@2x.png", 32)]


def compose_app_icon(logo: Image.Image) -> Image.Image:
    """保留母图留白，圆角交给系统。"""
    canvas = Image.new("RGBA", (CANVAS, CANVAS), BACKDROP)
    scaled = logo.copy()
    scaled.thumbnail((CANVAS, CANVAS), Image.LANCZOS)
    canvas.alpha_composite(scaled, ((CANVAS - scaled.width) // 2, (CANVAS - scaled.height) // 2))
    return canvas.convert("RGB")


def sharpen_alpha(alpha: Image.Image, low: int = 96, high: int = 168) -> Image.Image:
    """把中间的半透明拉成陡坡：菜单栏图标只有 18pt，软边会糊成一团。"""
    def curve(value: int) -> int:
        if value <= low:
            return 0
        if value >= high:
            return 255
        return int((value - low) * 255 / (high - low))

    return alpha.point(curve)


def silhouette(logo: Image.Image, size: int) -> Image.Image:
    """模板图：黑色剪影 + 原始 alpha，系统会按明暗自动着色。"""
    bounds = logo.getchannel("A").point(lambda value: 255 if value >= 8 else 0).getbbox()
    if bounds is None:
        raise ValueError("Logo has no visible pixels")
    scaled = logo.crop(bounds)
    scaled.thumbnail((size, size), Image.LANCZOS)
    ink = Image.new("RGBA", scaled.size, (0, 0, 0, 255))
    ink.putalpha(sharpen_alpha(scaled.getchannel("A")))
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(ink, ((size - scaled.width) // 2, (size - scaled.height) // 2))
    return canvas


def write_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "pack",
        nargs="?",
        default=None,
        help="图标资源包目录（含 PNG/）；省略时用仓库里的 Assets/logo-1024.png",
    )
    parser.add_argument("--out", default="Resources", help="输出目录")
    parser.add_argument("--preview", default="/tmp/iine-verify/evidence")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.pack:
        logo_path = Path(args.pack).expanduser() / "PNG" / "Logo-Transparent-1024.png"
    else:
        # 仓库自带母图，不依赖外面那份资源包。
        logo_path = root / "Assets" / "logo-1024.png"
    logo = Image.open(logo_path).convert("RGBA")

    icon = compose_app_icon(logo)
    write_png(icon.resize((512, 512), Image.LANCZOS), root / "Assets" / "app-icon.png")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        for name, size in ICONSET_SIZES:
            write_png(icon.resize((size, size), Image.LANCZOS), iconset / name)
        icns = Path(tmp) / "AppIcon.icns"
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
        shutil.copyfile(icns, out / "AppIcon.icns")

    for name, size in STATUS_SIZES:
        write_png(silhouette(logo, size), out / name)
    for name, size in MENU_SIZES:
        write_png(silhouette(logo, size), out / name)

    preview = Path(args.preview)
    write_png(icon, preview / "app-icon-1024.png")
    write_png(icon.resize((256, 256), Image.LANCZOS), preview / "app-icon-256.png")
    print("WROTE", out / "AppIcon.icns")
    print("PREVIEW", preview / "app-icon-1024.png")


if __name__ == "__main__":
    main()
