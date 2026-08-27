"""Generate transparent-background splash glyph assets for flutter_native_splash.

Two outputs:
  - splash_logo.png: full-size glyph (matches the app icon's envelope
    geometry and "Brushed Steel Envelope" flap/rivet treatment — see
    tool/gen_icon.py) for iOS / Android pre-12 / web, where
    flutter_native_splash itself centers the image on the solid
    background color.
  - splash_logo_android12.png: the same glyph scaled down so all opaque
    pixels stay within Android 12's circular safe zone (per current
    platform guidance, icon content must stay within the inner ~2/3 of
    the canvas — https://developer.android.com/develop/ui/views/launch/splash-screen).
    Scale is tuned to reproduce the same on-canvas bounding box as the
    pre-enlargement glyph, so the safe-zone fit doesn't change when the
    glyph itself is resized.

Both are fully transparent outside the glyph — no background fill, unlike
assets/icon/app_icon.png (which has an opaque square baked in for the
app icon itself and is NOT reused here). The splash screen's own solid
background color (pubspec.yaml's flutter_native_splash: color/color_dark)
is set separately to a dark slate-blue picked from the icon's gradient,
since native splash APIs only support a flat fill, not a gradient.
"""
import numpy as np
from PIL import Image, ImageDraw

SIZE = 1024
WHITE = (244, 246, 248, 255)  # matches gen_icon.py's envelope-body white


def _hex(color: str) -> tuple[int, int, int]:
    color = color.lstrip("#")
    return tuple(int(color[i : i + 2], 16) for i in (0, 2, 4))


def linear_gradient(
    size: tuple[int, int],
    stops: list[tuple[float, str]],
    p0: tuple[float, float],
    p1: tuple[float, float],
) -> np.ndarray:
    """Same helper as gen_icon.py's — an (h, w, 3) uint8 multi-stop linear
    gradient projected onto the vector from `p0` to `p1`."""
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


def radial_gradient_patch(diameter: int, inner: str, outer: str, focal_offset: tuple[float, float]) -> Image.Image:
    """Same helper as gen_icon.py's — a small square RGBA patch: a radial
    gradient circle, focal point offset from center by `focal_offset`
    (fraction of radius)."""
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


def draw_envelope(canvas_size, scale=1.0):
    """Draws the envelope glyph — brushed-steel gradient flap + blue
    riveted-seal accent, matching gen_icon.py's "Brushed Steel Envelope"
    geometry exactly — on a transparent canvas of canvas_size, scaled by
    `scale` around the canvas center. scale=1.0 reproduces the exact
    geometry used for the app icon's glyph (720x420 body, dead-centered)."""
    img = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    body_w, body_h = int(720 * scale), int(488 * scale)
    left = (canvas_size - body_w) // 2
    top = (canvas_size - body_h) // 2
    right = left + body_w
    bottom = top + body_h
    radius = int(65 * scale)

    draw.rounded_rectangle(
        [left, top, right, bottom], radius=radius, fill=WHITE,
        corners=(False, False, True, True),
    )
    draw.rectangle([left, top, right, top + radius], fill=WHITE)

    apex_y = top + int(221 * scale)
    flap_mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(flap_mask).polygon(
        [(left, top), (right, top), ((left + right) // 2, apex_y)], fill=255,
    )
    flap_grad = linear_gradient(
        (canvas_size, canvas_size), [(0.0, "#8896A3"), (1.0, "#3F4B57")], (left, top), (right, apex_y),
    )
    img = Image.composite(Image.fromarray(flap_grad).convert("RGBA"), img, flap_mask)

    rivet_d = max(int(60 * scale), 2)
    rivet_cx, rivet_cy = (left + right) // 2, apex_y
    rivet_patch = radial_gradient_patch(rivet_d, "#3E8CF0", "#06409E", focal_offset=(-0.30, -0.40))
    img.alpha_composite(rivet_patch, (rivet_cx - rivet_d // 2, rivet_cy - rivet_d // 2))

    return img


# Full-size glyph — matches the icon exactly.
glyph = draw_envelope(SIZE, scale=1.0)
glyph.save("assets/icon/splash_logo.png", "PNG")

# Android 12 safe-zone variant — same shape, scaled to 0.534x so the
# glyph's bounding box (720x488 at scale=1.0) shrinks to the same
# on-canvas size the pre-enlargement 620x420 glyph had at its old 0.62x,
# which fits within the inner 682x682 safe zone with margin to spare.
glyph_a12 = draw_envelope(SIZE, scale=0.534)
glyph_a12.save("assets/icon/splash_logo_android12.png", "PNG")

print("saved splash_logo.png and splash_logo_android12.png")
