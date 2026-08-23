"""Generate the "Lock-Seal Envelope" app icon — the same envelope glyph the
app has always used, on a cobalt-blue diagonal sweep, with its flap
replaced by a brushed-silver keyhole: the mail is sealed/locked, a simple,
literal read on the app's strength/security/privacy themes. Chosen (over a
riveted-armor-plate direction that read as too busy at small sizes) from
four metal/armor concept directions explored on a design canvas.

iOS 26 ("Liquid Glass") guidance baked in (carried over from every prior
version of this generator):
  - Fully opaque, no alpha channel (transparency is disallowed/ignored on iOS 18+).
  - Full-bleed square, no manual corner rounding — the OS applies its own
    squircle mask and the Liquid Glass specular/refraction sweep on top.
  - Generous safe-area padding so the glyph isn't clipped by the more
    aggressive corner mask or washed out by the edge highlight.
  - Bold, simple geometry with strong contrast so it still reads clearly
    under the glass sheen, and at actual home-screen size — this direction
    was picked specifically for reading as "simple" next to the other,
    busier armor-plate concept.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

REPO_ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024


def _hex(color: str) -> tuple[int, int, int]:
    color = color.lstrip("#")
    return tuple(int(color[i : i + 2], 16) for i in (0, 2, 4))


def linear_gradient(
    size: tuple[int, int],
    stops: list[tuple[float, str]],
    p0: tuple[float, float],
    p1: tuple[float, float],
) -> np.ndarray:
    """An (h, w, 3) uint8 array: a multi-stop linear gradient over the full
    canvas, projected onto the vector from `p0` to `p1` — the same geometry
    a `<linearGradient x1 y1 x2 y2>` describes. `stops` is `[(offset, hex),
    ...]` with offsets in [0, 1], sorted ascending (matches SVG `<stop
    offset>` semantics).
    """
    w, h = size
    p0 = np.array(p0, dtype=np.float64)
    p1 = np.array(p1, dtype=np.float64)
    axis = p1 - p0
    length_sq = float(axis @ axis)
    xs, ys = np.meshgrid(np.arange(w), np.arange(h))
    px = np.stack([xs, ys], axis=-1).astype(np.float64) - p0
    t = (px @ axis / length_sq).clip(0, 1)

    result = np.zeros((h, w, 3), dtype=np.float64)
    for (off0, color0), (off1, color1) in zip(stops, stops[1:]):
        seg = (t >= off0) & (t <= off1)
        local_t = ((t - off0) / (off1 - off0))[..., None]
        c0, c1 = np.array(_hex(color0)), np.array(_hex(color1))
        blended = c0 * (1 - local_t) + c1 * local_t
        result = np.where(seg[..., None], blended, result)
    return result.astype(np.uint8)


def diagonal_highlight_band(size: int, angle_deg: float, y0: int, height: int, opacity: float) -> Image.Image:
    """A soft white diagonal band (RGBA), rotated about the canvas center —
    matches the source design's low-opacity diagonal "sheen" sweep across
    the background.
    """
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rectangle(
        [-size // 2, y0, size + size // 2, y0 + height],
        fill=(255, 255, 255, round(255 * opacity)),
    )
    return layer.rotate(angle_deg, center=(size / 2, size / 2), resample=Image.BICUBIC)


def main() -> None:
    # Background: cobalt-blue diagonal sweep (three stops — darker, brand
    # blue, lighter — for a gentle metallic gradation rather than a flat fill).
    bg = linear_gradient(
        (SIZE, SIZE),
        [(0.0, "#06409E"), (0.55, "#0A5BD6"), (1.0, "#1568E0")],
        (0, 0),
        (SIZE, SIZE),
    )
    img = Image.fromarray(bg).convert("RGBA")

    # A single soft diagonal highlight sweep — a hint of polish, not a
    # texture (see the design spec's note on fine brush-texture vanishing
    # at small icon sizes).
    highlight = diagonal_highlight_band(SIZE, angle_deg=-22, y0=120, height=80, opacity=0.14)
    img = Image.alpha_composite(img, highlight)

    # Envelope glyph — unchanged geometry from every prior version of this
    # icon.
    draw = ImageDraw.Draw(img)
    body_w, body_h = 620, 420
    left = (SIZE - body_w) // 2
    top = (SIZE - body_h) // 2 + 40
    right = left + body_w
    bottom = top + body_h
    radius = 56
    white = (244, 246, 248, 255)
    draw.rounded_rectangle([left, top, right, bottom], radius=radius, fill=white, corners=(False, False, True, True))
    draw.rectangle([left, top, right, top + radius], fill=white)

    # Lock-seal: the flap is replaced by a keyhole silhouette (a circle over
    # a tapered keyway) in a brushed-silver gradient — "sealed", not just
    # folded shut.
    silver = linear_gradient((SIZE, SIZE), [(0.0, "#E6EAEF"), (1.0, "#8C99A6")], (440, 400), (590, 600))
    silver_img = Image.fromarray(silver).convert("RGBA")

    keyhole_mask = Image.new("L", (SIZE, SIZE), 0)
    kd = ImageDraw.Draw(keyhole_mask)
    kd.ellipse([512 - 62, 470 - 62, 512 + 62, 470 + 62], fill=255)
    kd.polygon([(478, 486), (546, 486), (521, 588), (503, 588)], fill=255)
    img = Image.composite(silver_img, img, keyhole_mask)

    out_path = REPO_ROOT / "assets" / "icon" / "app_icon.png"
    img = img.convert("RGB")
    img.save(out_path, "PNG")
    print("saved", out_path, img.size, img.mode)


if __name__ == "__main__":
    main()
