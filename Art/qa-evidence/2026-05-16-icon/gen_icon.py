"""Posey 1.0 app icon generator.

Spec (Mark, 2026-05-16):
- 1024x1024 rounded-square (Xcode handles the corner radius mask)
- Very dark near-black background
- Single warm amber-gold radial glow centered
- Serif lowercase "p" in cream/white, sized to fill ~2/3 of canvas
  height, centered
- Glow sits BEHIND the p
- Matches the visual family of Mark's other apps (single light source,
  dark field, letterform-only)

Outputs three flavors per Apple's iOS 18+ AppIcon requirements:
- AppIcon-1024.png         (light/default)
- AppIcon-1024-Dark.png    (dark mode tint)
- AppIcon-1024-Tinted.png  (tinted monochrome — grayscale for system tint)
"""

import os
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SIZE = 1024
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/Posey-Icon"
os.makedirs(OUT, exist_ok=True)


def make_glow(center=(SIZE // 2, SIZE // 2),
              inner_color=(255, 184, 88),
              outer_color=(255, 142, 30),
              max_radius=int(SIZE * 0.62),
              intensity=1.0):
    """Procedural radial gradient that simulates a warm amber glow.
    Renders as RGBA so the dark base shows through the falloff."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    cx, cy = center
    for y in range(SIZE):
        for x in range(SIZE):
            dx = x - cx
            dy = y - cy
            d = (dx * dx + dy * dy) ** 0.5
            if d >= max_radius:
                continue
            t = d / max_radius
            # Smooth falloff. Custom curve to keep the hot center
            # warm and let the outer ring fade quickly.
            falloff = (1.0 - t) ** 2.2
            falloff *= intensity
            r = int(inner_color[0] * falloff + outer_color[0] * (1.0 - falloff))
            g = int(inner_color[1] * falloff + outer_color[1] * (1.0 - falloff))
            b = int(inner_color[2] * falloff + outer_color[2] * (1.0 - falloff))
            a = int(255 * falloff)
            px[x, y] = (r, g, b, a)
    # Soft blur to remove any pixel-stepping seams.
    img = img.filter(ImageFilter.GaussianBlur(radius=8))
    return img


def make_p_overlay(letter_color=(252, 247, 235),
                   font_size_pts=int(SIZE * 0.62)):
    """Render a centered serif lowercase 'p' as an RGBA overlay."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Baskerville reads as the most "serious reading" of the macOS
    # serifs and matches the Posey-as-quiet-companion vibe; the
    # descender on the 'p' is the dominant shape.
    font_path = "/System/Library/Fonts/Baskerville.ttc"
    try:
        font = ImageFont.truetype(font_path, font_size_pts)
    except Exception:
        # Fall back to Georgia which is universally present.
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Georgia.ttf",
                                  font_size_pts)
    text = "p"
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    # Position so the visual center of the letter (NOT the bounding
    # box midpoint) sits at the canvas center. For a lowercase 'p',
    # most of the visible weight is in the bowl + stem near the top;
    # the descender extends below. The visual center is roughly at
    # 40% of the bbox height from the top — adjust to push the
    # letter slightly upward so the descender clears the bottom and
    # the bowl reads as centered.
    x = (SIZE - text_w) // 2 - bbox[0]
    y = (SIZE - text_h) // 2 - bbox[1] - int(text_h * 0.04)
    draw.text((x, y), text, font=font, fill=letter_color)
    return img


def compose(bg_color, glow_color_inner, glow_color_outer,
            letter_color, letter_alpha=255):
    """Composite the full icon: dark bg → glow → letter."""
    bg = Image.new("RGBA", (SIZE, SIZE), bg_color)
    glow = make_glow(inner_color=glow_color_inner,
                     outer_color=glow_color_outer,
                     max_radius=int(SIZE * 0.78),
                     intensity=0.95)
    p_overlay = make_p_overlay(letter_color=letter_color)
    if letter_alpha != 255:
        # Re-do letter with alpha multiplier
        r, g, b = letter_color[:3]
        p_overlay = make_p_overlay(letter_color=(r, g, b, letter_alpha))
    composed = Image.alpha_composite(bg, glow)
    composed = Image.alpha_composite(composed, p_overlay)
    return composed


# Variant 1 — Light/default: dark near-black bg, warm glow, cream p
light = compose(
    bg_color=(11, 10, 14, 255),
    glow_color_inner=(255, 196, 110),
    glow_color_outer=(220, 110, 30),
    letter_color=(252, 247, 235),
)
light.convert("RGB").save(os.path.join(OUT, "AppIcon-1024.png"), "PNG", optimize=True)

# Variant 2 — Dark: deeper black bg, slightly cooler glow center
dark = compose(
    bg_color=(6, 6, 9, 255),
    glow_color_inner=(255, 184, 88),
    glow_color_outer=(200, 90, 20),
    letter_color=(245, 240, 228),
)
dark.convert("RGB").save(os.path.join(OUT, "AppIcon-1024-Dark.png"), "PNG", optimize=True)

# Variant 3 — Tinted: grayscale on transparent bg per Apple's spec.
# iOS composites this against the user's chosen tint color.
tinted = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
# A subtle gray radial glow + a near-white letter
gray_glow = make_glow(
    inner_color=(225, 225, 225),
    outer_color=(80, 80, 80),
    max_radius=int(SIZE * 0.58),
    intensity=0.6,
)
p_overlay = make_p_overlay(letter_color=(255, 255, 255))
tinted = Image.alpha_composite(tinted, gray_glow)
tinted = Image.alpha_composite(tinted, p_overlay)
tinted.save(os.path.join(OUT, "AppIcon-1024-Tinted.png"), "PNG", optimize=True)

print(f"Wrote three variants to {OUT}")
