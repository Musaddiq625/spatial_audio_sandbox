#!/usr/bin/env python3
"""Generate the Spatial Audio Sandbox brand artwork.

Radar-disc mark matching the in-app radar palette:
  dark disc (#10161F on #0B0E14), teal range rings + rim (#64D8CB),
  FOV wedge, head dot with nose notch, and three source dots in the
  app's kind colors (bee amber, rain cyan, pad purple).

Outputs:
  assets/branding/icon_1024.png      opaque square (macOS + legacy Android)
  assets/branding/icon_foreground.png transparent, glyph in adaptive safe zone
  assets/branding/brand_mark.png      transparent, tight glyph for in-app use
  android/app/src/main/res/drawable/splash_mark.png  launch-screen mark

Run:  python3 tool/gen_brand.py
"""

import math
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BG = (11, 14, 20, 255)          # #0B0E14 scaffold background
DISC = (16, 22, 31, 255)        # #10161F radar disc
TEAL = (100, 216, 203)          # #64D8CB radar accent
AMBER = (255, 193, 7)           # bee
CYAN = (79, 195, 247)           # rain
PURPLE = (186, 104, 200)        # pad
DIM = (70, 82, 98)              # range rings

S = 2048  # supersample canvas; downscale on save


def draw_mark(size, glyph_scale=1.0, opaque=False):
    """Render the radar mark at `size` px. glyph_scale shrinks the
    whole mark inside the canvas (used for the adaptive safe zone)."""
    img = Image.new("RGBA", (size, size), BG if opaque else (0, 0, 0, 0))
    d = ImageDraw.Draw(img, "RGBA")
    c = size / 2
    g = glyph_scale

    def r(v):
        return v * g

    # disc + rim — the disc sits just inside the canvas edge so the
    # launcher mask crops it into a full-bleed circular tile.
    d.ellipse([c - r(412), c - r(412), c + r(412), c + r(412)], fill=DISC)
    d.ellipse([c - r(398), c - r(398), c + r(398), c + r(398)],
              outline=TEAL + (255,), width=int(r(20)))

    # range rings
    for rr, a in ((130, 60), (250, 48), (356, 40)):
        d.ellipse([c - r(rr), c - r(rr), c + r(rr), c + r(rr)],
                  outline=DIM + (a,), width=int(r(9)))

    # crosshair ticks (N/E/S/W), low alpha
    for ang in (0, 90, 180, 270):
        x1 = c + r(130) * math.sin(math.radians(ang))
        y1 = c - r(130) * math.cos(math.radians(ang))
        x2 = c + r(348) * math.sin(math.radians(ang))
        y2 = c - r(348) * math.cos(math.radians(ang))
        d.line([x1, y1, x2, y2], fill=DIM + (36,), width=int(r(8)))

    # FOV wedge pointing "up" (front) — soft directional glow, kept
    # subtle so the head dot stays dominant at launcher sizes.
    half = math.radians(30)
    p1 = (c + r(360) * math.sin(-half), c - r(360) * math.cos(-half))
    p2 = (c + r(360) * math.sin(half), c - r(360) * math.cos(half))
    d.polygon([(c, c - r(58)), p1, p2], fill=TEAL + (16,))
    p1 = (c + r(300) * math.sin(-half), c - r(300) * math.cos(-half))
    p2 = (c + r(300) * math.sin(half), c - r(300) * math.cos(half))
    d.polygon([(c, c - r(58)), p1, p2], fill=TEAL + (10,))

    # source dots: bee upper-left, rain right, pad lower-left — each
    # with a small halo ring, like the app's source badges.
    def dot(deg, dist, color, rr=34):
        x = c + r(dist) * math.sin(math.radians(deg))
        y = c - r(dist) * math.cos(math.radians(deg))
        d.ellipse([x - r(rr), y - r(rr), x + r(rr), y + r(rr)],
                  fill=color + (255,))
        d.ellipse([x - r(rr + 16), y - r(rr + 16), x + r(rr + 16), y + r(rr + 16)],
                  outline=color + (150,), width=int(r(7)))

    dot(-38, 235, AMBER)
    dot(62, 250, CYAN)
    dot(215, 200, PURPLE, rr=30)

    # head dot + nose notch (the listener, facing "up") — dark inner
    # ring keeps it legible against the wedge glow.
    d.ellipse([c - r(56), c - r(56), c + r(56), c + r(56)],
              fill=DISC)
    d.ellipse([c - r(56), c - r(56), c + r(56), c + r(56)],
              outline=TEAL + (255,), width=int(r(10)))
    d.polygon([(c - r(16), c - r(50)), (c + r(16), c - r(50)),
               (c, c - r(84))], fill=TEAL + (255,))

    return img


def save(img, path, size):
    from PIL import ImageFilter
    img = img.resize((size, size), Image.LANCZOS)
    # mild unsharp — downscaling softens the thin ring strokes
    img = img.filter(ImageFilter.UnsharpMask(radius=2, percent=70))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("wrote", os.path.relpath(path, ROOT))


def main():
    out = os.path.join(ROOT, "assets", "branding")
    save(draw_mark(S, opaque=True), os.path.join(out, "icon_1024.png"), 1024)
    # Adaptive foreground: full-bleed disc — the launcher mask crops it
    # into a circular radar tile. All detail lives inside the 66% safe
    # zone already (dots at r<=250, rings at <=356 of 512 half-canvas).
    save(draw_mark(S, glyph_scale=1.0),
         os.path.join(out, "icon_foreground.png"), 1024)
    save(draw_mark(S), os.path.join(out, "brand_mark.png"), 720)
    save(draw_mark(S), os.path.join(
        ROOT, "android", "app", "src", "main", "res", "drawable",
        "splash_mark.png"), 288)


if __name__ == "__main__":
    main()
