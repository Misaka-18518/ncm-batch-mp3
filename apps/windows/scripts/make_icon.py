#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter


ASSETS = Path(__file__).resolve().parents[1] / "assets"
MAC_ICON = Path(__file__).resolve().parents[3] / ".build" / "AppIcon.iconset" / "icon_512x512.png"


def fallback_icon(size: int = 1024) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    radius = int(size * 0.23)
    draw.rounded_rectangle(
        (48, 48, size - 48, size - 48),
        radius=radius,
        fill=(226, 251, 252, 255),
        outline=(255, 255, 255, 220),
        width=10,
    )
    for offset, color in [
        ((150, 120, 760, 650), (37, 99, 235, 48)),
        ((290, 300, 900, 920), (8, 166, 184, 56)),
        ((70, 620, 600, 990), (255, 184, 90, 42)),
    ]:
        layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse(offset, fill=color)
        image.alpha_composite(layer.filter(ImageFilter.GaussianBlur(55)))

    draw = ImageDraw.Draw(image)
    draw.ellipse((215, 210, 640, 635), fill=(255, 255, 255, 235), outline=(8, 166, 184, 100), width=12)
    draw.ellipse((352, 347, 502, 497), fill=(223, 250, 253, 255), outline=(18, 60, 82, 70), width=6)

    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 260)
        small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 120)
    except Exception:
        font = ImageFont.load_default()
        small = ImageFont.load_default()

    draw.text((340, 220), "♪", fill=(18, 48, 66, 255), font=font, anchor="mm")
    draw.rounded_rectangle((575, 570, 855, 770), radius=48, fill=(245, 248, 255, 240), outline=(37, 99, 235, 110), width=8)
    draw.text((715, 630), "MP3", fill=(37, 99, 235, 255), font=small, anchor="mm")
    draw.line((520, 680, 605, 680), fill=(8, 166, 184, 255), width=28)
    draw.polygon([(605, 620), (700, 680), (605, 740)], fill=(8, 166, 184, 255))
    return image


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    if MAC_ICON.exists():
        icon = Image.open(MAC_ICON).convert("RGBA")
    else:
        icon = fallback_icon()

    png = icon.resize((512, 512), Image.Resampling.LANCZOS)
    png.save(ASSETS / "icon.png")
    ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    icon.save(ASSETS / "icon.ico", sizes=ico_sizes)
    print(f"wrote {ASSETS / 'icon.ico'}")


if __name__ == "__main__":
    main()
