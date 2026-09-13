"""Generates Encore's launcher icons from the same geometry as EncoreMarkPainter."""
import json
import os
from PIL import Image, ImageDraw

ROOT = "/Users/softtronics/Desktop/Utils/open_source/encore"

EMBER_BRIGHT = (0xFF, 0x8A, 0x52)
EMBER = (0xF2, 0x62, 0x2B)
EMBER_DEEP = (0xB8, 0x42, 0x0F)
INK = (0x0B, 0x0B, 0x0C)
BASE = (0x0B, 0x0B, 0x0C)

BARS = [0.34, 0.72, 0.50, 0.90, 0.42]
BAR_W = 0.086
GAP = 0.062
BAR_SPAN = 0.62
CORNER = 0.08

BASE_SIZE = 1024
SS = 4  # supersample factor for the shape masks


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size):
    """The mark's field: one flat colour.

    Kept under the old name so the rest of the script reads unchanged. It was
    a diagonal three-stop ember ramp with a white highlight along the top —
    a lit glass tile, which is what almost every app icon looks like. The
    painted mark in `brand.dart` is flat now and the launcher icon has to
    agree with it, or the app introduces itself as one thing and opens as
    another.
    """
    return Image.new("RGB", (size, size), EMBER)


def mask(size, shape):
    """Renders `shape(draw, scale)` supersampled, returns an 8-bit mask."""
    big = Image.new("L", (size * SS, size * SS), 0)
    shape(ImageDraw.Draw(big), size * SS)
    return big.resize((size, size), Image.LANCZOS)


def squircle(draw, size):
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=size * CORNER, fill=255)


def bars(draw, size, span=BAR_SPAN, canvas=None):
    """Draws the bar rhythm for a `size` box, centred on a `canvas` box."""
    canvas = canvas or size
    width = size * BAR_W
    gap = size * GAP
    total = len(BARS) * width + (len(BARS) - 1) * gap
    x = (canvas - total) / 2
    centre = canvas / 2
    for fraction in BARS:
        height = size * span * fraction
        draw.rectangle(
            [x, centre - height / 2, x + width, centre + height / 2],
            fill=255,
        )
        x += width + gap


def mark(size=BASE_SIZE, full_bleed=True, bar_span=BAR_SPAN):
    icon = gradient(size).convert("RGBA")
    if full_bleed:
        icon.putalpha(mask(size, squircle))
    else:
        icon.putalpha(255)
    ink = Image.new("RGBA", (size, size), INK + (255,))
    icon = Image.alpha_composite(
        icon, Image.composite(ink, Image.new("RGBA", (size, size)), mask(size, lambda d, s: bars(d, s, bar_span)))
    )
    return icon


def write(image, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.resize((size, size), Image.LANCZOS).save(path)
    print(f"  {os.path.relpath(path, ROOT)} ({size}px)")


def main():
    print("Rendering the mark…")
    icon = mark()
    # An adaptive foreground is the bars alone, scaled to sit inside Android's
    # 66/108 safe zone; the gradient becomes the background drawable.
    safe = 66 / 108
    foreground = Image.new("RGBA", (BASE_SIZE, BASE_SIZE), INK + (0,))
    foreground.putalpha(
        mask(BASE_SIZE, lambda d, s: bars(d, s * safe, BAR_SPAN, canvas=s))
    )

    print("macOS")
    for size in (16, 32, 64, 128, 256, 512, 1024):
        write(icon, f"{ROOT}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png", size)

    print("Android launcher")
    for folder, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        write(icon, f"{ROOT}/android/app/src/main/res/mipmap-{folder}/ic_launcher.png", size)

    print("Android adaptive foreground")
    for folder, size in (("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)):
        write(foreground, f"{ROOT}/android/app/src/main/res/mipmap-{folder}/ic_launcher_foreground.png", size)

    print("Android splash mark")
    for folder, size in (("mdpi", 96), ("hdpi", 144), ("xhdpi", 192), ("xxhdpi", 288), ("xxxhdpi", 384)):
        write(icon, f"{ROOT}/android/app/src/main/res/drawable-{folder}/splash_mark.png", size)

    print("iOS")
    ios = f"{ROOT}/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    if os.path.isdir(ios):
        with open(f"{ios}/Contents.json") as handle:
            contents = json.load(handle)
        for entry in contents["images"]:
            if "filename" not in entry:
                continue
            scale = int(entry.get("scale", "1x").rstrip("x"))
            side = float(entry["size"].split("x")[0])
            write(icon, f"{ios}/{entry['filename']}", round(side * scale))

    print("Web")
    for name, size in (("Icon-192", 192), ("Icon-512", 512)):
        write(icon, f"{ROOT}/web/icons/{name}.png", size)
    # Maskable icons need the mark inset so a circular crop cannot clip it.
    for name, size in (("Icon-maskable-192", 192), ("Icon-maskable-512", 512)):
        canvas = Image.new("RGBA", (BASE_SIZE, BASE_SIZE), BASE + (255,))
        inset = round(BASE_SIZE * 0.20)
        canvas.paste(icon.resize((BASE_SIZE - 2 * inset,) * 2, Image.LANCZOS), (inset, inset), icon.resize((BASE_SIZE - 2 * inset,) * 2, Image.LANCZOS))
        write(canvas, f"{ROOT}/web/icons/{name}.png", size)
    write(icon, f"{ROOT}/web/favicon.png", 32)


main()
