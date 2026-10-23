#!/usr/bin/env python3
"""Compare QEMU HMP P6 screendumps before and after a keyboard movement."""
import sys


def read_ppm(path):
    with open(path, "rb") as source:
        if source.readline().strip() != b"P6":
            raise ValueError("expected QEMU P6 screenshot")
        tokens = []
        while len(tokens) < 3:
            line = source.readline()
            if not line:
                raise ValueError("truncated PPM header")
            line = line.split(b"#", 1)[0]
            tokens.extend(line.split())
        width, height, maximum = map(int, tokens[:3])
        if maximum != 255 or width <= 0 or height <= 0:
            raise ValueError("unsupported PPM geometry")
        pixels = source.read()
        if len(pixels) != width * height * 3:
            raise ValueError("invalid PPM payload length")
        return width, height, pixels


def compare(before, after):
    width, height, original = read_ppm(before)
    new_width, new_height, updated = read_ppm(after)
    if (width, height) != (new_width, new_height):
        raise ValueError("framebuffer resolution changed")
    changed = 0
    left, top, right, bottom = width, height, -1, -1
    for offset in range(0, len(original), 3):
        if original[offset:offset + 3] == updated[offset:offset + 3]:
            continue
        pixel = offset // 3
        x, y = pixel % width, pixel // width
        changed += 1
        left, top = min(left, x), min(top, y)
        right, bottom = max(right, x), max(bottom, y)
    if changed == 0:
        raise ValueError("no visible pixels changed after arrow key")
    print(f"ok: QEMU framebuffer changed {changed} pixels, bbox=({left},{top})-({right},{bottom})")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: compare-framebuffer.py before.ppm after.ppm")
        compare(sys.argv[1], sys.argv[2])
    except (OSError, ValueError) as error:
        print(f"framebuffer comparison failed: {error}", file=sys.stderr)
        sys.exit(1)
