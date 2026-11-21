"""Draw the Hard Counters icon: a gold number sign on dark slate, made in code (AI-assisted, like the rest of the repo).

Writes, from the repo root:
  HardCounters/Media/Icon.tga   64x64, 32-bit RGBA, uncompressed: the minimap button, AddOn list, compartment, portrait
  docs/media/logo.png           512x512 PNG: the start of the CurseForge logo
Run in WSL (needs Pillow): python3 tools/draw-icon.py
"""
import os
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
S = 512  # drawn at this size, downsampled for the icon
GOLD_TOP, GOLD_BOT = (255, 222, 120), (214, 150, 30)
OUTLINE = (40, 22, 4)
BG_CENTER, BG_EDGE = (52, 60, 78), (10, 12, 18)


def background():
    bg = Image.new("RGBA", (S, S))
    px = bg.load()
    c = S / 2
    for y in range(S):
        for x in range(S):
            d = min(1.0, (((x - c) ** 2 + (y - c * 0.85) ** 2) ** 0.5) / (S * 0.72))
            px[x, y] = tuple(int(BG_CENTER[i] + (BG_EDGE[i] - BG_CENTER[i]) * d) for i in range(3)) + (255,)
    return bg


def gold():
    g = Image.new("RGBA", (S, S))
    d = ImageDraw.Draw(g)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(int(GOLD_TOP[i] + (GOLD_BOT[i] - GOLD_TOP[i]) * t) for i in range(3)) + (255,))
    return g


def number_sign():
    m = Image.new("L", (S, S))
    d = ImageDraw.Draw(m)
    t = 0.11

    def poly(pts):
        d.polygon([(x * S, y * S) for x, y in pts], fill=255)

    poly([(0.36, 0.16), (0.36 + t, 0.16), (0.30 + t, 0.84), (0.30, 0.84)])
    poly([(0.60, 0.16), (0.60 + t, 0.16), (0.54 + t, 0.84), (0.54, 0.84)])
    d.rectangle([0.16 * S, 0.33 * S, 0.84 * S, (0.33 + t) * S], fill=255)
    d.rectangle([0.16 * S, 0.56 * S, 0.84 * S, (0.56 + t) * S], fill=255)
    return m


def compose(mask):
    img = background()
    img.paste(Image.new("RGBA", (S, S), OUTLINE + (255,)), (0, 0), mask.filter(ImageFilter.MaxFilter(23)))
    img.paste(gold(), (0, 0), mask)
    highlight = ImageChops.multiply(mask, Image.linear_gradient("L").resize((S, S)).rotate(180).point(lambda v: int(v * 0.35)))
    img.paste(Image.new("RGBA", (S, S), (255, 255, 255, 255)), (0, 0), highlight)
    return img


def main():
    art = compose(number_sign())
    os.makedirs(os.path.join(ROOT, "HardCounters", "Media"), exist_ok=True)
    os.makedirs(os.path.join(ROOT, "docs", "media"), exist_ok=True)
    # Pillow writes TGA uncompressed with a bottom-left origin by default, which the client reads.
    art.resize((64, 64), Image.LANCZOS).save(os.path.join(ROOT, "HardCounters", "Media", "Icon.tga"))
    art.save(os.path.join(ROOT, "docs", "media", "logo.png"))


if __name__ == "__main__":
    main()
