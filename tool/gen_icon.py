"""Generate the "Riveted Armor Plate" app icon — a gunmetal/cobalt diagonal
background, a raised riveted metal panel, and the same white envelope glyph
the app has always used, now clad in armor. Chosen from four metal/armor
concept directions explored on a design canvas (see
docs/superpowers/specs — this replaces the earlier flat two-tone blue
envelope) to symbolize the app's strength/security/privacy themes.

iOS 26 ("Liquid Glass") guidance baked in (carried over from the previous
generator):
  - Fully opaque, no alpha channel (transparency is disallowed/ignored on iOS 18+).
  - Full-bleed square, no manual corner rounding — the OS applies its own
    squircle mask and the Liquid Glass specular/refraction sweep on top.
  - Generous safe-area padding so the glyph isn't clipped by the more
    aggressive corner mask or washed out by the edge highlight.
  - Bold, simple geometry with strong contrast so it still reads clearly
    under the glass sheen — and, just as important here, at actual
    home-screen size: the "armor" reads as gradient shading and a few
    rivets, not fine brushed-metal texture, which turns to mud once the
    icon is shrunk past ~60px.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

REPO_ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024


def _hex(color: str) -> tuple[int, int, int]:
    color = color.lstrip("#")
    return tuple(int(color[i : i + 2], 16) for i in (0, 2, 4))


def diagonal_gradient(size: tuple[int, int], start: str, end: str, origin: tuple[int, int] = (0, 0)) -> np.ndarray:
    """An (h, w, 3) uint8 array, linearly interpolated along the (1, 1)
    diagonal from `start` at `origin` to `end` at `origin + size` — the same
    gradient vector `<linearGradient x1 y1 x2 y2>` describes when x2-x1 ==
    y2-y1 (every gradient in the source design is exactly this diagonal).
    """
    w, h = size
    start_rgb = np.array(_hex(start), dtype=np.float64)
    end_rgb = np.array(_hex(end), dtype=np.float64)
    xs, ys = np.meshgrid(np.arange(w), np.arange(h))
    t = ((xs + ys) / (2 * max(w + h - 2, 1))).clip(0, 1)
    t = t[..., None]
    grad = start_rgb * (1 - t) + end_rgb * t
    return grad.astype(np.uint8)


def rounded_rect_mask(size: tuple[int, int], box: tuple[int, int, int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


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
    # Background: gunmetal-to-cobalt diagonal sweep.
    bg = diagonal_gradient((SIZE, SIZE), "#0F1B2E", "#0A5BD6")
    img = Image.fromarray(bg).convert("RGBA")

    # Riveted panel — a raised metal plate filling most of the safe area.
    panel_box = (140, 140, 140 + 744, 140 + 744)
    panel_grad = diagonal_gradient((744, 744), "#4A6480", "#1E2E40")
    panel_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    panel_layer.paste(Image.fromarray(panel_grad), (140, 140))
    panel_mask = rounded_rect_mask((SIZE, SIZE), panel_box, radius=64)
    img = Image.composite(panel_layer, img, panel_mask)

    # Inset highlight border — suggests the panel's raised bevel edge.
    border_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(border_layer).rounded_rectangle(
        (172, 172, 172 + 680, 172 + 680),
        radius=48,
        outline=(143, 166, 188, int(255 * 0.35)),
        width=4,
    )
    img = Image.alpha_composite(img, border_layer)

    # Four corner rivets, each a small embossed radial-gradient bead.
    rivet_d = 44  # 2 * r=22
    rivet_patch = radial_gradient_patch(rivet_d, "#B9C6D2", "#5A6B7A", focal_offset=(-0.30, -0.40))
    for cx, cy in [(212, 212), (812, 212), (212, 812), (812, 812)]:
        img.alpha_composite(rivet_patch, (cx - rivet_d // 2, cy - rivet_d // 2))

    # Envelope glyph — unchanged geometry from every prior version of this
    # icon, kept flat/opaque (not metallic) so it stays the clearest, most
    # legible element against the armored backdrop.
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
    apex_y = top + 190
    draw.polygon([(left, top), (right, top), ((left + right) // 2, apex_y)], fill=(6, 64, 158, 255))

    out_path = REPO_ROOT / "assets" / "icon" / "app_icon.png"
    img = img.convert("RGB")
    img.save(out_path, "PNG")
    print("saved", out_path, img.size, img.mode)


if __name__ == "__main__":
    main()
