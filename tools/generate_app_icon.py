#!/usr/bin/env python3
"""Draw the app icon.

A script rather than a file somebody made once in a graphics editor and cannot
change: the colours come from `Theme.swift` and the shapes are five rectangles.
When the palette moves, this moves with it.

The result is one 1024×1024 image with no transparency and no rounded corners —
iOS applies its own mask, and a corner drawn here would sit inside that one and
look like a mistake.

Run: python tools/generate_app_icon.py
"""

from __future__ import annotations

import json
import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "ios/AppIcon/AppIcon.appiconset"

SIZE = 1024
#: Drawn large and shrunk, which is the cheapest way to get clean curves.
SCALE = 4

#: `Theme.Hour.morning` — the most recognisable of the five, and the one on
#: screen for most of the waking day.
FROM = (0x1E, 0x5F, 0xCC)
TO = (0x2F, 0xA8, 0xD9)
#: `Theme.swatches[0]`, the red the app uses for "important" and for now.
ACCENT = (0xFF, 0x6B, 0x6B)


def gradient(size: int) -> Image.Image:
    """Diagonal, with a soft light at the top right — as `HeaderBackground`."""
    small = 64
    base = Image.new("RGB", (small, small))
    pixels = base.load()
    for y in range(small):
        for x in range(small):
            # Along the diagonal, so the corners are the two stops.
            t = (x + y) / (2 * (small - 1))
            pixels[x, y] = tuple(
                round(start + (end - start) * t) for start, end in zip(FROM, TO)
            )

    highlight = Image.new("L", (small, small))
    glow = highlight.load()
    for y in range(small):
        for x in range(small):
            dx = (x - small * 0.78) / (small * 0.62)
            dy = (y - small * 0.18) / (small * 0.62)
            distance = (dx * dx + dy * dy) ** 0.5
            glow[x, y] = round(max(0.0, 1.0 - distance) * 70)

    base = base.resize((size, size), Image.BICUBIC)
    highlight = highlight.resize((size, size), Image.BICUBIC)
    return Image.composite(Image.new("RGB", (size, size), (255, 255, 255)), base, highlight)


def draw_calendar(image: Image.Image) -> None:
    """A calendar, in the plainest terms: a body, a band, two rings, some days."""
    size = image.size[0]
    draw = ImageDraw.Draw(image)
    unit = size / 1024  # so the numbers below read as they would at 1024

    body = (232 * unit, 268 * unit, 792 * unit, 812 * unit)
    radius = 78 * unit
    stroke = 44 * unit

    draw.rounded_rectangle(body, radius=radius, outline=(255, 255, 255), width=round(stroke))

    # The band across the top, clipped to the body's corners by drawing the same
    # rounded rectangle and cutting it off below the band.
    band = Image.new("L", image.size, 0)
    ImageDraw.Draw(band).rounded_rectangle(body, radius=radius, fill=255)
    ImageDraw.Draw(band).rectangle(
        (0, 268 * unit + 132 * unit, size, size), fill=0
    )
    image.paste(Image.new("RGB", image.size, (255, 255, 255)), (0, 0), band)

    # The rings, standing above the band.
    for x in (356 * unit, 668 * unit):
        draw.rounded_rectangle(
            (x - 26 * unit, 196 * unit, x + 26 * unit, 310 * unit),
            radius=26 * unit,
            fill=(255, 255, 255),
        )

    # Two rows of days. One of them is today.
    dot = 46 * unit
    left = 318 * unit
    gap = 156 * unit
    for row, top in enumerate((530 * unit, 676 * unit)):
        for column in range(3):
            x = left + column * gap
            colour = ACCENT if (row, column) == (0, 1) else (255, 255, 255)
            draw.rounded_rectangle(
                (x, top, x + dot, top + dot), radius=14 * unit, fill=colour
            )


def main() -> None:
    canvas = SIZE * SCALE
    image = gradient(canvas)
    draw_calendar(image)
    image = image.resize((SIZE, SIZE), Image.LANCZOS)

    OUTPUT.mkdir(parents=True, exist_ok=True)
    image.save(OUTPUT / "icon-1024.png")

    # One image for everything: Xcode 14 and later ask for a single size and
    # produce the rest.
    (OUTPUT / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    {
                        "filename": "icon-1024.png",
                        "idiom": "universal",
                        "platform": "ios",
                        "size": "1024x1024",
                    }
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        )
        + "\n"
    )
    print(f"wrote {OUTPUT.relative_to(ROOT)}/icon-1024.png")


if __name__ == "__main__":
    main()
