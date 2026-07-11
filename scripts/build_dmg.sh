#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/dmg"
PY_DEPS_DIR="$ROOT_DIR/.build/dmg-py"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="NCM批量转MP3"
APP_PATH="$DIST_DIR/$APP_NAME.app"
VOLUME_NAME="$APP_NAME"
ARCH_NAME="macOS-arm64"

if [[ ! -d "$APP_PATH" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
FINAL_DMG="$DIST_DIR/$APP_NAME-$VERSION-$ARCH_NAME.dmg"
BACKGROUND_PATH="$BUILD_DIR/arrow.png"
SETTINGS_PATH="$BUILD_DIR/dmg-settings.py"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$PY_DEPS_DIR" "$DIST_DIR"

if ! PYTHONPATH="$PY_DEPS_DIR" python3 -c 'import dmgbuild' >/dev/null 2>&1; then
  python3 -m pip install --target "$PY_DEPS_DIR" dmgbuild
fi

python3 - "$BACKGROUND_PATH" <<'PY'
import math
import struct
import sys
import zlib

out_path = sys.argv[1]
width, height, scale = 600, 380, 3
sw, sh = width * scale, height * scale
bg = (250, 251, 252, 255)
ink = (24, 24, 24, 255)
pixels = bytearray(bg * (sw * sh))

def set_px(x, y, color):
    if 0 <= x < sw and 0 <= y < sh:
        i = (y * sw + x) * 4
        pixels[i:i + 4] = bytes(color)

def fill_circle(cx, cy, radius, color):
    x0, x1 = int(cx - radius), int(cx + radius) + 1
    y0, y1 = int(cy - radius), int(cy + radius) + 1
    r2 = radius * radius
    for y in range(y0, y1):
        for x in range(x0, x1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r2:
                set_px(x, y, color)

def draw_line(x1, y1, x2, y2, thickness, color):
    x1, y1, x2, y2, thickness = [v * scale for v in (x1, y1, x2, y2, thickness)]
    dx, dy = x2 - x1, y2 - y1
    length2 = dx * dx + dy * dy
    radius = thickness / 2
    x0, x1b = sorted((int(min(x1, x2) - radius), int(max(x1, x2) + radius) + 1))
    y0, y1b = sorted((int(min(y1, y2) - radius), int(max(y1, y2) + radius) + 1))
    for y in range(y0, y1b):
        for x in range(x0, x1b):
            if length2 == 0:
                dist = math.hypot(x - x1, y - y1)
            else:
                t = max(0, min(1, ((x - x1) * dx + (y - y1) * dy) / length2))
                px, py = x1 + t * dx, y1 + t * dy
                dist = math.hypot(x - px, y - py)
            if dist <= radius:
                set_px(x, y, color)
    fill_circle(x1, y1, radius, color)
    fill_circle(x2, y2, radius, color)

def fill_polygon(points, color):
    pts = [(int(x * scale), int(y * scale)) for x, y in points]
    min_y, max_y = min(y for _, y in pts), max(y for _, y in pts)
    for y in range(min_y, max_y + 1):
        nodes = []
        j = len(pts) - 1
        for i, (xi, yi) in enumerate(pts):
            xj, yj = pts[j]
            if (yi < y <= yj) or (yj < y <= yi):
                nodes.append(int(xi + (y - yi) / (yj - yi) * (xj - xi)))
            j = i
        nodes.sort()
        for i in range(0, len(nodes), 2):
            if i + 1 >= len(nodes):
                break
            for x in range(nodes[i], nodes[i + 1] + 1):
                set_px(x, y, color)

draw_line(247, 190, 350, 190, 12, ink)
fill_polygon([(371, 190), (333, 156), (333, 224)], ink)

raw = bytearray()
for y in range(height):
    raw.append(0)
    for x in range(width):
        acc = [0, 0, 0, 0]
        for yy in range(scale):
            for xx in range(scale):
                idx = (((y * scale + yy) * sw) + (x * scale + xx)) * 4
                for c in range(4):
                    acc[c] += pixels[idx + c]
        raw.extend(bytes(round(v / (scale * scale)) for v in acc))

def chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )

png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    + chunk(b"IEND", b"")
)
with open(out_path, "wb") as f:
    f.write(png)
PY

python3 - "$SETTINGS_PATH" "$APP_PATH" "$APP_NAME.app" "$BACKGROUND_PATH" <<'PY'
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
app_path = pathlib.Path(sys.argv[2])
app_name = sys.argv[3]
background_path = pathlib.Path(sys.argv[4])

settings_path.write_text(
    "\n".join(
        [
            'format = "UDZO"',
            'filesystem = "HFS+"',
            "compression_level = 9",
            "window_rect = ((120, 120), (600, 380))",
            "default_view = 'icon-view'",
            "show_status_bar = False",
            "show_toolbar = False",
            "show_sidebar = False",
            "icon_size = 112",
            "text_size = 12",
            "grid_spacing = 100",
            "arrange_by = None",
            f"background = {str(background_path)!r}",
            f"files = [({str(app_path)!r}, {app_name!r})]",
            "symlinks = {'Applications': '/Applications'}",
            f"icon_locations = {{{app_name!r}: (160, 190), 'Applications': (440, 190)}}",
            "hide = ['.background.png']",
            "",
        ]
    ),
    encoding="utf-8",
)
PY

echo "Creating DMG..."
PYTHONPATH="$PY_DEPS_DIR" python3 -m dmgbuild \
  "$VOLUME_NAME" \
  "$FINAL_DMG" \
  --settings "$SETTINGS_PATH" \
  --no-hidpi \
  --detach-retries 12

hdiutil internet-enable -no "$FINAL_DMG" >/dev/null 2>&1 || true

echo "Done: $FINAL_DMG"
