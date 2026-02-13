#!/usr/bin/env python3
"""
Generate iOS + macOS AppIcon.appiconset PNGs from a single 1024x1024 source image.

Usage:
  python3 scripts/generate_app_icons.py /absolute/path/to/source.png

Notes:
- iOS App Store requires opaque icons. This script always writes RGB PNGs (no alpha).
- It reads each AppIcon.appiconset/Contents.json and overwrites referenced filenames.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
APPICONSETS = [
    ROOT / "iOS" / "EchoApp" / "Assets.xcassets" / "AppIcon.appiconset",
    ROOT / "macOS" / "EchoMac" / "Assets.xcassets" / "AppIcon.appiconset",
]

def center_crop_square(img: Image.Image) -> Image.Image:
    w, h = img.size
    side = min(w, h)
    left = (w - side) // 2
    top = (h - side) // 2
    return img.crop((left, top, left + side, top + side))


def flatten_alpha(img: Image.Image) -> Image.Image:
    """
    App icons must be fully opaque (no alpha channel).
    If the source has transparency, composite onto a matte color sampled from the corner.
    """
    if img.mode in ("RGBA", "LA") or ("transparency" in img.info):
        rgba = img.convert("RGBA")
        r, g, b, _a = rgba.getpixel((0, 0))
        matte = Image.new("RGBA", rgba.size, (r, g, b, 255))
        return Image.alpha_composite(matte, rgba).convert("RGB")
    return img.convert("RGB")


def parse_size(size_str: str) -> tuple[float, float]:
    w_str, h_str = size_str.split("x")
    return float(w_str), float(h_str)


def parse_scale(scale_str: str) -> float:
    if not scale_str.endswith("x"):
        raise ValueError(f"Unexpected scale: {scale_str}")
    return float(scale_str[:-1])


def px(size: float, scale: float) -> int:
    # Apple sizes like 83.5@2x => 167 px.
    return int(round(size * scale))


def generate_for_appiconset(appiconset: Path, src: Image.Image) -> None:
    contents_path = appiconset / "Contents.json"
    data = json.loads(contents_path.read_text(encoding="utf-8"))
    images = data.get("images", [])

    for item in images:
        filename = item.get("filename")
        size_str = item.get("size")
        scale_str = item.get("scale")
        if not filename or not size_str or not scale_str:
            continue

        w_pt, h_pt = parse_size(size_str)
        scale = parse_scale(scale_str)
        out_w = px(w_pt, scale)
        out_h = px(h_pt, scale)

        # App icons are always square in these catalogs, but keep it generic.
        if out_w <= 0 or out_h <= 0:
            continue

        # High-quality downscale.
        out = src.resize((out_w, out_h), resample=Image.Resampling.LANCZOS).convert("RGB")
        out_path = appiconset / filename
        out.save(out_path, format="PNG", optimize=True)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/generate_app_icons.py /path/to/source.png", file=sys.stderr)
        return 2

    src_path = Path(sys.argv[1]).expanduser().resolve()
    if not src_path.exists():
        print(f"Source not found: {src_path}", file=sys.stderr)
        return 2

    src = Image.open(src_path)
    # Ensure consistent sizing without distorting aspect ratio:
    # center-crop to square, then scale to 1024.
    src = center_crop_square(src)
    src = src.resize((1024, 1024), resample=Image.Resampling.LANCZOS)
    src = flatten_alpha(src)

    for appiconset in APPICONSETS:
        if not (appiconset / "Contents.json").exists():
            print(f"Missing Contents.json in {appiconset}", file=sys.stderr)
            return 2
        generate_for_appiconset(appiconset, src)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
