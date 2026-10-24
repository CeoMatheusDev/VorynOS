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


def paint_row(row, width, y, rect, color):
    """Paints the visible part of one row of an opaque rectangle."""
    x, rect_y, rect_width, rect_height = rect
    if not (rect_y <= y < rect_y + rect_height):
        return
    left = max(0, x)
    right = min(width, x + rect_width)
    if right > left:
        row[left * 3:right * 3] = color * (right - left)


def expected_row(width, y, background_row, back, back_rect, front, front_rect):
    row = bytearray(background_row)
    paint_row(row, width, y, back_rect, back)
    paint_row(row, width, y, front_rect, front)
    return row


def first_difference(actual, expected, width, y):
    for index, (left, right) in enumerate(zip(actual, expected)):
        if left != right:
            return index // 3, y, actual[index:index + 3], expected[index:index + 3]
    return 0, y, b"", b""


def clipped_area(rect, width, height):
    x, y, rect_width, rect_height = rect
    left = max(0, x)
    right = min(width, x + rect_width)
    top = max(0, y)
    bottom = min(height, y + rect_height)
    if right <= left or bottom <= top:
        return 0
    return (right - left) * (bottom - top)


def intersection_area(first, second, width, height):
    ax, ay, aw, ah = first
    bx, by, bw, bh = second
    left = max(ax, bx)
    right = min(ax + aw, bx + bw)
    top = max(ay, by)
    bottom = min(ay + ah, by + bh)
    if right <= left or bottom <= top:
        return 0
    return (max(0, min(width, right) - max(0, left)) *
            max(0, min(height, bottom) - max(0, top)))


def compare(before, after, old_x, old_y, new_x, new_y):
    width, height, original = read_ppm(before)
    new_width, new_height, updated = read_ppm(after)
    if (width, height) != (new_width, new_height):
        raise ValueError("framebuffer resolution changed")
    if not (0 <= old_x < width and 0 <= new_x < width
            and 0 <= old_y < height and 0 <= new_y < height):
        raise ValueError("window position outside framebuffer")

    # A clamped movement must not alter any pixel. The comparison is a
    # single bytes comparison, not a per-pixel loop.
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

    # Validate every pixel by constructing each expected row as bytes. The
    # old implementation visited every pixel in Python, which took seconds
    # for a 2048x2048 framebuffer and distorted the measured throughput.
    background_row = background * width
    row_bytes = width * 3
    mismatch_before = 0
    mismatch_after = 0
    first_error = None

    for y in range(height):
        offset = y * row_bytes
        before_row = expected_row(width, y, background_row, back, back_rect, front, front_before)
        after_row = expected_row(width, y, background_row, back, back_rect, front, front_after)
        previous = original[offset:offset + row_bytes]
        current = updated[offset:offset + row_bytes]
        if previous != before_row:
            mismatch_before += 1
            if first_error is None:
                x, row, actual, expected = first_difference(previous, before_row, width, y)
                first_error = ("before", x, row, actual, expected)
        if current != after_row:
            mismatch_after += 1
            if first_error is None:
                x, row, actual, expected = first_difference(current, after_row, width, y)
                first_error = ("after", x, row, actual, expected)

    if mismatch_before or mismatch_after:
        raise ValueError(
            f"geometry mismatch: before={mismatch_before} rows, "
            f"after={mismatch_after} rows, first={first_error}"
        )

    # The scene is made of opaque solid layers. Pixels in the intersection
    # of the two front-window positions are unchanged, so the changed area
    # is the symmetric difference, computed geometrically.
    changed = (clipped_area(front_before, width, height)
               + clipped_area(front_after, width, height)
               - 2 * intersection_area(front_before, front_after, width, height))
    if changed == 0:
        raise ValueError("no visible pixels changed after arrow key")
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
