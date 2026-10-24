#!/usr/bin/env python3
"""Compare a QEMU P6 screendump with a user-space composition checksum.

The application composes a grayscale frame in its own buffer, presents it
through `present` and prints an FNV-1a 64 checksum over the visible low byte
of every pixel. This script reads the same rectangle from the QEMU
screenshot, verifies that every pixel is grayscale (so the comparison does
not depend on the GOP RGB/BGR byte order) and compares the checksum.

Usage:
    compare-presentation.py screenshot.ppm x y width height checksum
"""
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


def fnv1a64(data):
    value = 0xCBF29CE484222325
    for byte in data:
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def compare(path, x, y, width, height, expected):
    image_width, image_height, pixels = read_ppm(path)
    if x < 0 or y < 0 or width <= 0 or height <= 0:
        raise ValueError("invalid presentation rectangle")
    if x + width > image_width or y + height > image_height:
        raise ValueError("presentation rectangle outside the screenshot")

    visible = bytearray()
    for row in range(y, y + height):
        offset = (row * image_width + x) * 3
        for _ in range(width):
            red, green, blue = pixels[offset:offset + 3]
            if red != green or green != blue:
                raise ValueError(
                    f"non-grayscale pixel at ({x + len(visible) % width}, {row})"
                )
            visible.append(red)
            offset += 3

    actual = fnv1a64(visible)
    if actual != expected:
        raise ValueError(
            f"composition checksum mismatch: screenshot=0x{actual:016x}, "
            f"application=0x{expected:016x}"
        )
    print(
        f"ok: QEMU presentation exact, {width}x{height} at {x},{y}, "
        f"checksum=0x{actual:016x}"
    )


if __name__ == "__main__":
    try:
        if len(sys.argv) != 7:
            raise ValueError(
                "usage: compare-presentation.py screenshot.ppm x y width height checksum"
            )
        compare(
            sys.argv[1],
            *map(int, sys.argv[2:6]),
            int(sys.argv[6], 16),
        )
    except (OSError, ValueError) as error:
        print(f"presentation comparison failed: {error}", file=sys.stderr)
        sys.exit(1)
