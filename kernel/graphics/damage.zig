//************************************************************************//
//  damage.zig                                                            //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! F6.4: rastreamento de danos por janela, sem heap e sem acesso a MMIO.
//! Uma janela opaca que apenas se desloca invalida somente as faixas
//! expostas; mudanças de cor, tamanho ou visibilidade invalidam as duas
//! geometrias completas.

const std = @import("std");
const compositor = @import("compositor.zig");
const raster = @import("raster.zig");

pub const Rect = compositor.Rect;
pub const Window = compositor.Window;

pub const Tracker = struct {
    pub const capacity = 32;
    rects: [capacity]Rect = undefined,
    count: usize = 0,
    full: bool = false,

    pub fn invalidate(self: *Tracker, bounds: Rect, rect: Rect) void {
        if (self.full) return;
        const clipped = clipRect(bounds, rect) orelse return;
        if (self.count == capacity) {
            self.full = true;
            self.count = 0;
            return;
        }
        self.rects[self.count] = clipped;
        self.count += 1;
    }

    /// Invalida a parte de `rect` que não está coberta por `covered`.
    ///
    /// Os dois retângulos são recortados aos limites da tela antes da
    /// aritmética, portanto as somas não podem transbordar. A diferença é
    /// decomposta em até quatro retângulos disjuntos, sem sobreposição.
    fn invalidateDifference(self: *Tracker, bounds: Rect, rect: Rect, covered: Rect) void {
        const clipped = clipRect(bounds, rect) orelse return;
        const cover = clipRect(bounds, covered) orelse {
            self.invalidate(bounds, clipped);
            return;
        };
        const left = @max(clipped.x, cover.x);
        const top = @max(clipped.y, cover.y);
        const right = @min(clipped.x + clipped.width, cover.x + cover.width);
        const bottom = @min(clipped.y + clipped.height, cover.y + cover.height);
        if (right <= left or bottom <= top) {
            self.invalidate(bounds, clipped);
            return;
        }
        const clipped_right = clipped.x + clipped.width;
        const clipped_bottom = clipped.y + clipped.height;
        self.invalidate(bounds, .{ .x = clipped.x, .y = clipped.y, .width = clipped.width, .height = top - clipped.y });
        self.invalidate(bounds, .{ .x = clipped.x, .y = bottom, .width = clipped.width, .height = clipped_bottom - bottom });
        self.invalidate(bounds, .{ .x = clipped.x, .y = top, .width = left - clipped.x, .height = bottom - top });
        self.invalidate(bounds, .{ .x = right, .y = top, .width = clipped_right - right, .height = bottom - top });
    }

    pub fn redraw(self: *Tracker, surface: *raster.Surface, background: [4]u8, windows: []const Window) usize {
        if (self.full) {
            compositor.compose(surface, background, windows);
            self.reset();
            return surface.width * surface.height;
        }
        var pixels: usize = 0;
        for (self.rects[0..self.count]) |rect| {
            pixels += compositor.composeDirty(surface, background, windows, rect);
        }
        self.reset();
        return pixels;
    }

    pub fn reset(self: *Tracker) void {
        self.count = 0;
        self.full = false;
    }
};

/// Recorta um retângulo aos limites da tela.
/// Retorna null quando não sobra área visível.
fn clipRect(bounds: Rect, rect: Rect) ?Rect {
    if (rect.width == 0 or rect.height == 0) return null;
    if (rect.x >= bounds.width or rect.y >= bounds.height) return null;
    const width = @min(rect.width, bounds.width - rect.x);
    const height = @min(rect.height, bounds.height - rect.y);
    if (width == 0 or height == 0) return null;
    return .{ .x = rect.x, .y = rect.y, .width = width, .height = height };
}

pub fn boundsOf(window: Window) Rect {
    return .{ .x = window.x, .y = window.y, .width = if (window.visible) window.width else 0, .height = if (window.visible) window.height else 0 };
}

/// Substitui uma janela e invalida a geometria anterior e a posterior.
///
/// Uma janela opaca que só mudou de posição mantém intacta a interseção das
/// duas geometrias; repintá-la seria trabalho sem efeito visível. As faixas
/// expostas são suficientes e, para um deslocamento pequeno, são uma fração
/// da área da janela. Se a aparência mudou, nada pode ser preservado e as
/// duas geometrias completas são invalidadas.
pub fn updateWindow(tracker: *Tracker, bounds: Rect, window: *Window, next: Window) void {
    const previous = window.*;
    window.* = next;
    const same_appearance = previous.visible == next.visible and
        previous.width == next.width and
        previous.height == next.height and
        std.mem.eql(u8, &previous.color, &next.color);
    if (!same_appearance) {
        tracker.invalidate(bounds, boundsOf(previous));
        tracker.invalidate(bounds, boundsOf(next));
        return;
    }
    const previous_bounds = boundsOf(previous);
    const next_bounds = boundsOf(next);
    tracker.invalidateDifference(bounds, previous_bounds, next_bounds);
    tracker.invalidateDifference(bounds, next_bounds, previous_bounds);
}

test "moving a window restores its previous location without touching unrelated pixels" {
    var pixels: [64]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    var windows = [_]Window{
        .{ .x = 0, .y = 0, .width = 2, .height = 2, .color = .{ 1, 1, 1, 1 } },
        .{ .x = 3, .y = 3, .width = 1, .height = 1, .color = .{ 9, 9, 9, 9 } },
    };
    compositor.compose(&surface, .{ 0, 0, 0, 0 }, &windows);
    var tracker: Tracker = .{};
    updateWindow(&tracker, .{ .x = 0, .y = 0, .width = 4, .height = 4 }, &windows[0], .{
        .x = 1, .y = 0, .width = 2, .height = 2, .color = .{ 2, 2, 2, 2 },
    });
    try std.testing.expectEqual(@as(usize, 8), tracker.redraw(&surface, .{ 0, 0, 0, 0 }, &windows));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2 }, pixels[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, pixels[60..64]);
    try std.testing.expectEqual(@as(usize, 0), tracker.count);
}

test "hiding a window restores the window below" {
    var pixels: [16]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 2, 2, 8);
    var windows = [_]Window{
        .{ .x = 0, .y = 0, .width = 2, .height = 2, .color = .{ 3, 3, 3, 3 } },
        .{ .x = 0, .y = 0, .width = 1, .height = 1, .color = .{ 7, 7, 7, 7 } },
    };
    compositor.compose(&surface, .{ 0, 0, 0, 0 }, &windows);
    var tracker: Tracker = .{};
    var hidden = windows[1];
    hidden.visible = false;
    updateWindow(&tracker, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, &windows[1], hidden);
    try std.testing.expectEqual(@as(usize, 1), tracker.redraw(&surface, .{ 0, 0, 0, 0 }, &windows));
    try std.testing.expectEqualSlices(u8, &.{ 3, 3, 3, 3 }, pixels[0..4]);
}

test "tracker falls back to full redraw when capacity is exhausted" {
    var pixels: [16]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 2, 2, 8);
    var tracker: Tracker = .{};
    for (0..Tracker.capacity + 1) |_| tracker.invalidate(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try std.testing.expect(tracker.full);
    try std.testing.expectEqual(@as(usize, 4), tracker.redraw(&surface, .{ 5, 5, 5, 5 }, &.{}));
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 5, 5 }, pixels[0..4]);
    try std.testing.expect(!tracker.full);
}

test "F6.10 successive moves restore background and preserve overlapping back window" {
    const background: [4]u8 = .{ 0, 0, 0, 0 };
    const back: [4]u8 = .{ 1, 1, 1, 1 };
    const front: [4]u8 = .{ 2, 2, 2, 2 };
    var pixels: [96]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 6, 4, 24);
    var windows = [_]Window{
        .{ .x = 1, .y = 1, .width = 3, .height = 2, .color = back },
        .{ .x = 2, .y = 1, .width = 2, .height = 2, .color = front },
    };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 6, .height = 4 };
    compositor.compose(&surface, background, &windows);

    const positions = [_][2]usize{ .{ 4, 1 }, .{ 0, 0 }, .{ 2, 1 }, .{ 3, 2 } };
    for (positions) |position| {
        var next = windows[1];
        next.x = position[0];
        next.y = position[1];
        var tracker: Tracker = .{};
        updateWindow(&tracker, bounds, &windows[1], next);
        try std.testing.expect(tracker.redraw(&surface, background, &windows) > 0);

        // Oraculo independente: recomposicao completa deve produzir os
        // mesmos pixels que a recomposicao incremental em cada movimento.
        var reference_pixels: [96]u8 = @splat(0);
        var reference = try raster.Surface.init(&reference_pixels, 6, 4, 24);
        compositor.compose(&reference, background, &windows);
        try std.testing.expectEqualSlices(u8, &reference_pixels, &pixels);
    }
}

test "F6.15 clipping restores pixels when window moves partially offscreen" {
    const background: [4]u8 = .{ 0, 0, 0, 0 };
    const back: [4]u8 = .{ 1, 1, 1, 1 };
    const front: [4]u8 = .{ 2, 2, 2, 2 };
    var pixels: [96]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 6, 4, 24);
    var windows = [_]Window{
        .{ .x = 1, .y = 1, .width = 4, .height = 2, .color = back },
        .{ .x = 2, .y = 1, .width = 3, .height = 2, .color = front },
    };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 6, .height = 4 };
    compositor.compose(&surface, background, &windows);
    const positions = [_][2]usize{
        .{ 5, 3 }, // Only one pixel remains visible.
        .{ 6, 4 }, // Entire front window is outside the framebuffer.
        .{ 0, 0 }, // Re-enter at the top-left corner.
        .{ 4, 2 }, // Right/bottom clipping.
        .{ 2, 1 }, // Restore the initial overlap.
    };
    for (positions) |position| {
        var next = windows[1];
        next.x = position[0];
        next.y = position[1];
        var tracker: Tracker = .{};
        updateWindow(&tracker, bounds, &windows[1], next);
        _ = tracker.redraw(&surface, background, &windows);

        var expected_pixels: [96]u8 = @splat(0);
        var reference = try raster.Surface.init(&expected_pixels, 6, 4, 24);
        compositor.compose(&reference, background, &windows);
        try std.testing.expectEqualSlices(u8, &expected_pixels, &pixels);
    }
}

test "F6.24 an opaque move invalidates only the exposed strips" {
    const background: [4]u8 = .{ 0, 0, 0, 0 };
    const back: [4]u8 = .{ 1, 1, 1, 1 };
    const front: [4]u8 = .{ 2, 2, 2, 2 };
    var pixels: [8 * 6 * 4]u8 = @splat(0xaa);
    var surface = try raster.Surface.init(&pixels, 8, 6, 32);
    var windows = [_]Window{
        .{ .x = 1, .y = 1, .width = 5, .height = 3, .color = back },
        .{ .x = 2, .y = 2, .width = 3, .height = 2, .color = front },
    };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 8, .height = 6 };
    compositor.compose(&surface, background, &windows);

    var next = windows[1];
    next.x = 4;
    var tracker: Tracker = .{};
    updateWindow(&tracker, bounds, &windows[1], next);
    // The old geometry covers x=2..4 and the new one x=4..6, for two rows.
    // Only x=2,3 and x=5,6 are exposed: 2*2 + 2*2 = 8 pixels, not 12.
    try std.testing.expectEqual(@as(usize, 8), tracker.redraw(&surface, background, &windows));

    var reference_pixels: [8 * 6 * 4]u8 = @splat(0xaa);
    var reference = try raster.Surface.init(&reference_pixels, 8, 6, 32);
    compositor.compose(&reference, background, &windows);
    try std.testing.expectEqualSlices(u8, &reference_pixels, &pixels);
}
