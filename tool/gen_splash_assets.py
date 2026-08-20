"""Generate transparent-background splash glyph assets for flutter_native_splash.

Two outputs:
  - splash_logo.png: full-size glyph (matches the app icon's envelope
    geometry) for iOS / Android pre-12 / web, where flutter_native_splash
    itself centers the image on the solid background color.
  - splash_logo_android12.png: the same glyph scaled down so all opaque
    pixels stay within Android 12's circular safe zone (per current
    platform guidance, icon content must stay within the inner ~2/3 of
    the canvas — https://developer.android.com/develop/ui/views/launch/splash-screen).

Both are fully transparent outside the glyph — no background fill, unlike
assets/icon/app_icon.png (which has an opaque square baked in for the
app icon itself and is NOT reused here).
"""
from PIL import Image, ImageDraw

SIZE = 1024
WHITE = (255, 255, 255, 255)
FLAP = (6, 64, 158, 255)  # matches gen_icon.py's FLAP color, alpha added


def draw_envelope(canvas_size, scale=1.0):
    """Draws the envelope glyph on a transparent canvas of canvas_size,
    scaled by `scale` around the canvas center. scale=1.0 reproduces the
    exact geometry used for the app icon's glyph."""
    img = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    body_w, body_h = int(620 * scale), int(420 * scale)
    left = (canvas_size - body_w) // 2
    top = (canvas_size - body_h) // 2 + int(40 * scale)
    right = left + body_w
    bottom = top + body_h
    radius = int(56 * scale)

    draw.rounded_rectangle(
        [left, top, right, bottom], radius=radius, fill=WHITE,
        corners=(False, False, True, True),
    )
    draw.rectangle([left, top, right, top + radius], fill=WHITE)

    apex_y = top + int(190 * scale)
    draw.polygon(
        [(left, top), (right, top), ((left + right) // 2, apex_y)],
        fill=FLAP,
    )
    return img


# Full-size glyph — matches the icon exactly.
glyph = draw_envelope(SIZE, scale=1.0)
glyph.save("assets/icon/splash_logo.png", "PNG")

# Android 12 safe-zone variant — same shape, scaled to 0.62x so the glyph's
# bounding box (620x420 at scale=1.0) shrinks to fit within the inner
# 682x682 safe zone with margin to spare.
glyph_a12 = draw_envelope(SIZE, scale=0.62)
glyph_a12.save("assets/icon/splash_logo_android12.png", "PNG")

print("saved splash_logo.png and splash_logo_android12.png")
