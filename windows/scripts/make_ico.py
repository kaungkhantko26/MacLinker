#!/usr/bin/env python3
"""Builds src/MacLinker.Windows/Resources/AppIcon.ico from the PNGs the Mac build already produces
(build/AppIcon.iconset). An .ico may contain PNG images directly, so no image library is needed."""
import pathlib, struct, sys

root = pathlib.Path(__file__).resolve().parents[2]
iconset = root / "build" / "AppIcon.iconset"
sizes = {16: "icon_16x16.png", 32: "icon_32x32.png", 48: "icon_32x32@2x.png", 64: "icon_64x64.png",
         128: "icon_128x128.png", 256: "icon_256x256.png"}
images = []
for size, name in sizes.items():
    path = iconset / name
    if not path.exists():
        sys.exit(f"missing {path}; run scripts/bundle.sh first to generate the icon set")
    images.append((size, path.read_bytes()))

out = bytearray(struct.pack("<HHH", 0, 1, len(images)))
offset = 6 + 16 * len(images)
for size, data in images:
    out += struct.pack("<BBBBHHII", 0 if size >= 256 else size, 0 if size >= 256 else size, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
for _, data in images:
    out += data
dest = root / "windows" / "src" / "MacLinker.Windows" / "Resources" / "AppIcon.ico"
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_bytes(out)
print(f"wrote {dest} ({len(out)} bytes, {len(images)} sizes)")
