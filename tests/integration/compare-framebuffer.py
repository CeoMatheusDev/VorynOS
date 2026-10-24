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


def compare(before, after, old_x, old_y, new_x, new_y):
    width, height, original = read_ppm(before)
    new_width, new_height, updated = read_ppm(after)
    if (width, height) != (new_width, new_height):
        raise ValueError("framebuffer resolution changed")
    if not (0 <= old_x < width and 0 <= new_x < width
            and 0 <= old_y < height and 0 <= new_y < height):
        raise ValueError("window position outside framebuffer")

    # A clamped movement must not alter any pixel. At (0, 0), the front
    # window covers the usual background sample, so skip scene sampling.
    if (old_x, old_y) == (new_x, new_y):
        if original != updated:
            first = next(i for i, (a, b) in enumerate(zip(original, updated)) if a != b)
            raise ValueError(f"framebuffer changed despite clamped movement at byte {first}")
        print(f"ok: clamped framebuffer unchanged ({old_x},{old_y}), {width}x{height}")
        return

    front_width, front_height = width // 2, height // 3
    back_rect = (width // 8, height // 8, width // 2, height // 2)
    front_before = (old_x, old_y, front_width, front_height)
    front_after = (new_x, new_y, front_width, front_height)

    def contains(rect, x, y):
        rx, ry, rw, rh = rect
        return rx <= x < rx + rw and ry <= y < ry + rh

    def pixel(data, x, y):
        index = (y * width + x) * 3
        return data[index:index + 3]

    # The demo paints three opaque solid-color layers. Sampling known,
    # unoccluded points avoids assumptions about GOP RGB/BGR byte ordering.
    background = pixel(original, 0, 0)
    back = pixel(original, width // 8, height // 8)
    front = pixel(original, old_x, old_y)
    if len({background, back, front}) != 3:
        raise ValueError("scene colors are not distinguishable")

    def expected(x, y, front_rect):
        if contains(front_rect, x, y):
            return front
        if contains(back_rect, x, y):
            return back
        return background

    changed = 0
    mismatch_before = 0
    mismatch_after = 0
    first_error = None
    for y in range(height):
        for x in range(width):
            previous = pixel(original, x, y)
            current = pixel(updated, x, y)
            want_before = expected(x, y, front_before)
            want_after = expected(x, y, front_after)
            if previous != want_before:
                mismatch_before += 1
                if first_error is None:
                    first_error = ("before", x, y, previous, want_before)
            if current != want_after:
                mismatch_after += 1
                if first_error is None:
                    first_error = ("after", x, y, current, want_after)
            if previous != current:
                changed += 1
    if mismatch_before or mismatch_after:
        raise ValueError(
            f"geometry mismatch: before={mismatch_before} after={mismatch_after}, "
            f"first={first_error}"
        )
    if changed == 0 and (old_x, old_y) != (new_x, new_y):
        raise ValueError("no visible pixels changed after arrow key")
    if changed != 0 and (old_x, old_y) == (new_x, new_y):
        raise ValueError("framebuffer changed despite clamped keyboard movement")
    print(
        f"ok: QEMU framebuffer geometry exact, {changed} changed pixels, "
        f"front ({old_x},{old_y})->({new_x},{new_y}), "
        f"background restoration and overlap verified"
    )


if __name__ == "__main__":
    try:
        if len(sys.argv) != 7:
            raise ValueError("usage: compare-framebuffer.py before.ppm after.ppm old_x old_y new_x new_y")
        compare(sys.argv[1], sys.argv[2], *map(int, sys.argv[3:]))
    except (OSError, ValueError) as error:
        print(f"framebuffer comparison failed: {error}", file=sys.stderr)
        sys.exit(1)
