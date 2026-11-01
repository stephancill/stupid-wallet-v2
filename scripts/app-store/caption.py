"""Compose captioned App Store screenshots at the raw screenshot's native resolution.

App Store Connect rejects images whose dimensions differ from the device class, so the
caption and a scaled, rounded copy of the raw screenshot are drawn inside the same canvas.

Usage: uv run --with pillow scripts/app-store/caption.py <raw-dir> <out-dir>
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

CAPTIONS = {
    "01-home": ("Your ETH,", "across every network"),
    "02-portfolio": ("Every token,", "one portfolio"),
    "03-send": ("Send in a few taps",),
    "04-accounts": ("All your wallets", "in one place"),
    "05-connect": ("A wallet built", "into Safari"),
    "06-transaction": ("Know exactly what", "you are signing"),
    "07-sign-in": ("Review every", "signature"),
}
BACKGROUND = (242, 242, 247)
TEXT = (17, 17, 17)
FONT = "/System/Library/Fonts/SFNS.ttf"
CAPTION_FRACTION, SIDE_FRACTION = 0.17, 0.09


def compose(raw: Path, out: Path, lines: tuple[str, ...]) -> None:
    shot = Image.open(raw).convert("RGBA")
    width, height = shot.size
    canvas = Image.new("RGBA", (width, height), BACKGROUND + (255,))
    draw = ImageDraw.Draw(canvas)

    caption_height = int(height * CAPTION_FRACTION)
    size = int(width * 0.075)
    font = ImageFont.truetype(FONT, size)
    font.set_variation_by_name("Bold")
    line_height = int(size * 1.18)
    y = (caption_height - line_height * len(lines)) / 2 + int(height * 0.02)
    for line in lines:
        left, top, right, _ = font.getbbox(line)
        draw.text(((width - (right - left)) / 2 - left, y - top), line, font=font, fill=TEXT)
        y += line_height

    device_width = int(width * (1 - 2 * SIDE_FRACTION))
    device_height = int(device_width * height / width)
    radius = int(device_width * 0.09)
    origin = ((width - device_width) // 2, caption_height)
    device = shot.resize((device_width, device_height), Image.LANCZOS)
    mask = Image.new("L", device.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, device_width - 1, device_height - 1], radius=radius, fill=255
    )
    device.putalpha(mask)

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [origin[0], origin[1] + 12, origin[0] + device_width, origin[1] + device_height + 12],
        radius=radius,
        fill=(0, 0, 0, 70),
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))
    canvas.paste(device, origin, device)
    canvas.convert("RGB").save(out, "PNG")
    print(f"{out} {width}x{height}")


def main() -> None:
    raw_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    for raw in sorted(raw_dir.glob("*.png")):
        if raw.stem not in CAPTIONS:
            raise SystemExit(f"no caption for {raw.name}")
        compose(raw, out_dir / raw.name, CAPTIONS[raw.stem])


if __name__ == "__main__":
    main()
