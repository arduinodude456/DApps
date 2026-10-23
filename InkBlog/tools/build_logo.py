#!/usr/bin/env python3
"""Render the source-controlled monochrome InkBlog SVG as actual 1-bit assets."""
from pathlib import Path
from io import BytesIO
import cairosvg
from PIL import Image

root = Path(__file__).resolve().parents[1]
source = root / "assets" / "inkblog.svg"
for size in (32, 64, 128):
    data = cairosvg.svg2png(url=str(source), output_width=size, output_height=size)
    rgba = Image.open(BytesIO(data)).convert("RGBA")
    background = Image.new("RGBA", rgba.size, "white")
    background.alpha_composite(rgba)
    bitmap = background.convert("L").point(lambda value: 255 if value >= 128 else 0, "1")
    bitmap.save(root / "assets" / f"inkblog-{size}-1bit.png")
    if size == 64:
        bitmap.save(root / "assets" / "inkblog-1bit.bmp")
        bitmap.save(root / "assets" / "inkblog-1bit.pbm")
        lines = ["-- Generated from assets/inkblog.svg; 64x64 1-bit rows.", "return {"]
        for y in range(size):
            lines.append('    "' + ''.join("1" if bitmap.getpixel((x, y)) == 0 else "0" for x in range(size)) + '",')
        lines.append("}")
        (root / "assets" / "logo_rows.lua").write_text("\n".join(lines) + "\n")
print("SVG and 1-bit PNG/BMP/PBM assets ready.")
