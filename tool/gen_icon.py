"""Generate a flat, minimal, blue envelope app icon (Apple Mail / Outlook
territory — solid blue background, white envelope glyph, no teal).

iOS 26 ("Liquid Glass") guidance baked in:
  - Fully opaque, no alpha channel (transparency is disallowed/ignored on iOS 18+).
  - Full-bleed square, no manual corner rounding — the OS applies its own
    squircle mask and the Liquid Glass specular/refraction sweep on top.
  - Generous safe-area padding (content kept within ~76% of canvas) so the
    glyph isn't clipped by the more aggressive corner mask or washed out by
    the edge highlight.
  - Bold, simple geometry with strong contrast so it still reads clearly
    under the glass sheen.
"""
from pathlib import Path

from PIL import Image, ImageDraw

REPO_ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024

# Flat two-tone blue background.
BG = (10, 91, 214)        # system blue, #0A5BD6
FLAP = (6, 64, 158)       # darker blue for the flap, #06409E
WHITE = (255, 255, 255)


def main() -> None:
    img = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, SIZE, SIZE], fill=BG)

    # Envelope body — centered, within the safe area.
    body_w, body_h = 620, 420
    left = (SIZE - body_w) // 2
    top = (SIZE - body_h) // 2 + 40
    right = left + body_w
    bottom = top + body_h
    radius = 56

    # Rounded rectangle, only bottom corners rounded (top gets covered by flap).
    draw.rounded_rectangle(
        [left, top, right, bottom],
        radius=radius,
        fill=WHITE,
        corners=(False, False, True, True),
    )
    # Square off the top so the flap triangle sits flush against a hard edge.
    draw.rectangle([left, top, right, top + radius], fill=WHITE)

    # Flap — a flat, slightly darker triangle forming the classic envelope seam.
    apex_y = top + 190
    draw.polygon(
        [(left, top), (right, top), ((left + right) // 2, apex_y)],
        fill=FLAP,
    )

    out_path = REPO_ROOT / "assets" / "icon" / "app_icon.png"
    img.save(out_path, "PNG")
    print("saved", out_path, img.size, img.mode)


if __name__ == "__main__":
    main()
