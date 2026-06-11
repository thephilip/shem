#!/usr/bin/env python3
# scripts/generate_banner.py
# Usage: python scripts/generate_banner.py shem.png priv/banner.ansi
# Requires: pip install Pillow
import sys
from PIL import Image

img = Image.open(sys.argv[1]).convert("RGB")
width = 40
ratio = img.height / img.width
height = int(width * ratio * 0.55)
img = img.resize((width, height * 2), Image.LANCZOS)

lines = []
for y in range(0, height * 2, 2):
    line = ""
    for x in range(width):
        r1, g1, b1 = img.getpixel((x, y))
        r2, g2, b2 = img.getpixel((x, y + 1))
        line += f"\x1b[38;2;{r1};{g1};{b1}m\x1b[48;2;{r2};{g2};{b2}m▀"
    line += "\x1b[0m"
    lines.append(line)

out = "\n".join(lines) + "\n"
with open(sys.argv[2], "w") as f:
    f.write(out)

print(f"Banner written to {sys.argv[2]} ({width}x{height} cells, {len(out)} bytes)")
