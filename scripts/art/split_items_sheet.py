#!/usr/bin/env python3
"""Split scripts/art/source/ducat_items_sheet.png into the three board
sprites the design note names: data/purse.png, data/dagger.png, data/die.png.

The sheet is a nano-banana (gemini-2.5-flash-image) render of a coin purse, a
Renaissance dagger and a die on a flat chroma-green backdrop, drawn against
the Softmax cog as the style reference. Gemini returns no alpha and the
"pure green" comes back as *some* green with a tinted edge, so: take the
backdrop colour as the median of the border, flood-fill transparency in from
the frame (green highlights INSIDE an object survive), split the row on empty
columns, pad each part to a square and resize.

Run:  python3 scripts/art/split_items_sheet.py
"""

import os
from collections import deque

from PIL import Image

ROLES = ["purse", "dagger", "die"]
SIZE = 128
TOLERANCE = 64


def median_border(pixels, width, height):
    samples = []
    for x in range(width):
        samples.append(pixels[x, 0])
        samples.append(pixels[x, height - 1])
    for y in range(height):
        samples.append(pixels[0, y])
        samples.append(pixels[width - 1, y])
    channels = []
    for index in range(3):
        values = sorted(sample[index] for sample in samples)
        channels.append(values[len(values) // 2])
    return tuple(channels)


def key_out(image):
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    backdrop = median_border(pixels, width, height)

    def is_backdrop(x, y):
        r, g, b, _ = pixels[x, y]
        near = (abs(r - backdrop[0]) + abs(g - backdrop[1]) +
                abs(b - backdrop[2])) < TOLERANCE
        ## The render's contact shadow is a DARKER green than the border
        ## median, so a plain distance key leaves a fringe under each object.
        ## Nothing in this sheet is green, so green-dominant is backdrop too.
        return near or (g > r + 26 and g > b + 26)

    seen = [[False] * height for _ in range(width)]
    queue = deque()
    for x in range(width):
        for y in (0, height - 1):
            if not seen[x][y] and is_backdrop(x, y):
                seen[x][y] = True
                queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            if not seen[x][y] and is_backdrop(x, y):
                seen[x][y] = True
                queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        pixels[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height and not seen[nx][ny] \
                    and is_backdrop(nx, ny):
                seen[nx][ny] = True
                queue.append((nx, ny))
    return image


def columns_with_ink(image):
    width, height = image.size
    pixels = image.load()
    filled = []
    for x in range(width):
        for y in range(height):
            if pixels[x, y][3] > 24:
                filled.append(x)
                break
    return set(filled)


def split_runs(filled, width, gap=12):
    runs = []
    start = None
    empty = 0
    for x in range(width):
        if x in filled:
            if start is None:
                start = x
            empty = 0
        elif start is not None:
            empty += 1
            if empty >= gap:
                runs.append((start, x - empty))
                start = None
                empty = 0
    if start is not None:
        runs.append((start, width - 1))
    return runs


def square(image):
    box = image.getbbox()
    if box:
        image = image.crop(box)
    side = max(image.size) + 8
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(image, ((side - image.width) // 2,
                         (side - image.height) // 2))
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    root = os.path.normpath(root)
    sheet = key_out(Image.open(
        os.path.join(root, "scripts", "art", "source",
                     "ducat_items_sheet.png")))
    runs = split_runs(columns_with_ink(sheet), sheet.width)
    if len(runs) != len(ROLES):
        raise SystemExit(
            f"expected {len(ROLES)} objects on the sheet, found {len(runs)}: "
            f"{runs}")
    for role, (left, right) in zip(ROLES, runs):
        part = square(sheet.crop((left, 0, right + 1, sheet.height)))
        path = os.path.join(root, "data", f"{role}.png")
        part.save(path)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
