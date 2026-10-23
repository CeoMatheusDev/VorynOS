//************************************************************************//
//  damage.zig                                                            //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! F6.4: rastreamento de danos por janela, sem heap e sem acesso a MMIO.
//! Cada mutação invalida o retângulo antigo e o novo separadamente.

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
        if (self.full or rect.width == 0 or rect.height == 0) return;
        if (rect.x >= bounds.width or rect.y >= bounds.height) return;
        const width = @min(rect.width, bounds.width - rect.x);
        const height = @min(rect.height, bounds.height - rect.y);
        if (width == 0 or height == 0) return;
        if (self.count == capacity) {
            self.full = true;
            self.count = 0;
            return;
        }
        self.rects[self.count] = .{ .x = rect.x, .y = rect.y, .width = width, .height = height };
        self.count += 1;
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

pub fn boundsOf(window: Window) Rect {
    return .{ .x = window.x, .y = window.y, .width = if (window.visible) window.width else 0, .height = if (window.visible) window.height else 0 };
}

/// Substitui uma janela e invalida a geometria anterior e a posterior.
pub fn updateWindow(tracker: *Tracker, bounds: Rect, window: *Window, next: Window) void {
    tracker.invalidate(bounds, boundsOf(window.*));
    window.* = next;
    tracker.invalidate(bounds, boundsOf(next));
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
