"""Generate the "Brushed Steel Envelope" app icon — a blue diagonal
background ("Ocean Sweep": brighter and more mid-toned than the original
slate-gray sweep), the same white envelope glyph the app has always used,
with a brushed-steel triangular flap (a classic sealed-letter silhouette
rendered in metal) and a small blue riveted seal at the flap's point.
Chosen from four metal/armor concept directions explored on a design canvas
— a middle ground between the earlier "Riveted Armor Plate" (too busy at
small sizes) and "Lock-Seal Envelope" (no flap at all) directions: a
familiar envelope shape, metal-clad, with one clear accent rivet instead of
a busy panel. The envelope glyph itself was later enlarged ~16% and
recentered dead-center on the canvas (it was previously offset 40px below
center to balance an earlier, smaller flap).

iOS 26 ("Liquid Glass") guidance baked in (carried over from every prior
version of this generator):
  - Fully opaque, no alpha channel (transparency is disallowed/ignored on iOS 18+).
  - Full-bleed square, no manual corner rounding — the OS applies its own
    squircle mask and the Liquid Glass specular/refraction sweep on top.
  - Generous safe-area padding so the glyph isn't clipped by the more
    aggressive corner mask or washed out by the edge highlight.
  - Bold, simple geometry with strong contrast so it still reads clearly
    under the glass sheen, and at actual home-screen size — a gradient-clad
    flap and one accent rivet, not fine brushed-metal texture, which turns
    to mud once the icon is shrunk past ~60px.
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


def radial_gradient_patch(diameter: int, inner: str, outer: str, focal_offset: tuple[float, float]) -> Image.Image:
    """A small square RGBA patch: a radial gradient circle of `diameter`,
    focal point offset from center by `focal_offset` (fraction of radius,
    matching the source design's `radialGradient cx="35%" cy="30%"` — a
    light source from the upper-left, the standard "embossed rivet" cue).
    """
    r = diameter / 2
    inner_rgb = np.array(_hex(inner), dtype=np.float64)
    outer_rgb = np.array(_hex(outer), dtype=np.float64)
    xs, ys = np.meshgrid(np.arange(diameter), np.arange(diameter))
    fx, fy = r + focal_offset[0] * r, r + focal_offset[1] * r
    dist = np.sqrt((xs - fx) ** 2 + (ys - fy) ** 2)
    t = (dist / (r * 0.85)).clip(0, 1)[..., None]
    rgb = (inner_rgb * (1 - t) + outer_rgb * t).astype(np.uint8)
    circle_mask = np.sqrt((xs - r) ** 2 + (ys - r) ** 2) <= r
    rgba = np.dstack([rgb, np.where(circle_mask, 255, 0).astype(np.uint8)])
    return Image.fromarray(rgba)


def main() -> None:
    # Background: blue diagonal sweep (three stops, darkest at the
    # top-left corner) — "Ocean Sweep": brighter and more saturated than
    # the original slate-gray version, still dark enough at the top-left
    # corner to let the brushed-steel flap read clearly against it.
    bg = linear_gradient(
        (SIZE, SIZE),
        [(0.0, "#0D2A4A"), (0.55, "#1B5A96"), (1.0, "#4FA0E0")],
        (0, 0),
        (SIZE, SIZE),
    )
    img = Image.fromarray(bg).convert("RGBA")

    # Two soft diagonal highlight sweeps (a hint of polish, not a texture —
    # see the design spec's note on fine brush-texture vanishing at small
    # icon sizes) — matches the source design's pair of overlay bands.
    for y0, height in [(120, 90), (640, 60)]:
        img = Image.alpha_composite(img, diagonal_highlight_band(SIZE, angle_deg=-22, y0=y0, height=height, opacity=0.16))

    # Envelope body — ~16% larger than every prior version of this icon,
    # and dead-center on the canvas (previously offset 40px below center).
    draw = ImageDraw.Draw(img)
    body_w, body_h = 720, 488
    left = (SIZE - body_w) // 2
    top = (SIZE - body_h) // 2
    right = left + body_w
    bottom = top + body_h
    radius = 65
    white = (244, 246, 248, 255)
    draw.rounded_rectangle([left, top, right, bottom], radius=radius, fill=white, corners=(False, False, True, True))
    draw.rectangle([left, top, right, top + radius], fill=white)

    # Brushed-steel flap: a classic triangular envelope flap, filled with a
    # diagonal steel gradient (light upper-left to dark lower-right) rather
    # than a flat color — the "brushed steel" of the icon's name — with a
    # subtle dark seam stroke tracing its fold lines.
    apex_y = top + 221
    flap_mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(flap_mask).polygon([(left, top), (right, top), ((left + right) // 2, apex_y)], fill=255)
    flap_grad = linear_gradient((SIZE, SIZE), [(0.0, "#8896A3"), (1.0, "#3F4B57")], (left, top), (right, apex_y))
    img = Image.composite(Image.fromarray(flap_grad).convert("RGBA"), img, flap_mask)

    seam_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(seam_layer).line(
        [(left, top), ((left + right) // 2, apex_y), (right, top)],
        fill=(22, 33, 44, round(255 * 0.35)),
        width=7,
        joint="curve",
    )
    img = Image.alpha_composite(img, seam_layer)

    # Riveted seal at the flap's point — a small embossed radial-gradient
    # bead in the app's cobalt blue, with a white specular highlight dot.
    rivet_d = 60  # 2 * r=30
    rivet_cx, rivet_cy = (left + right) // 2, apex_y
    rivet_patch = radial_gradient_patch(rivet_d, "#3E8CF0", "#06409E", focal_offset=(-0.30, -0.40))
    img.alpha_composite(rivet_patch, (rivet_cx - rivet_d // 2, rivet_cy - rivet_d // 2))

    specular = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(specular).ellipse(
        [rivet_cx - 20, rivet_cy - 20, rivet_cx - 1, rivet_cy - 1],
        fill=(255, 255, 255, round(255 * 0.55)),
    )
    img = Image.alpha_composite(img, specular)

    out_path = REPO_ROOT / "assets" / "icon" / "app_icon.png"
    img = img.convert("RGB")
    img.save(out_path, "PNG")
    print("saved", out_path, img.size, img.mode)


if __name__ == "__main__":
    main()
