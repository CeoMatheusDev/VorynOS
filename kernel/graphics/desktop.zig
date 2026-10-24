// VorynOS F9: bounded, allocation-free managed desktop scene.
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only
//! Builds the boot desktop through the same owner-checked window manager
//! used by input and presentation. No physical memory access occurs here.
const std = @import("std");
const frame_mod = @import("frame.zig");
const bridge = @import("framebuffer_bridge.zig");
const renderer = @import("window_renderer.zig");
const wm = @import("window_manager.zig");
const compositor = @import("compositor.zig");

pub const system_owner: u64 = 1;

pub const Desktop = struct {
    frame: frame_mod.Frame,
    back: wm.Handle,
    front: wm.Handle,

    pub fn initInPlace(self: *Desktop, width: usize, height: usize, palette: renderer.Palette) !void {
        if (width == 0 or height == 0) return error.InvalidGeometry;
        self.* = .{ .frame = .{ .palette = palette }, .back = undefined, .front = undefined };
        try self.frame.session_state.registerClient(system_owner);
        self.back = try self.frame.createWindow(system_owner, width / 8, height / 8, @max(@as(usize, 1), width / 2), @max(@as(usize, 1), height / 2));
        self.front = try self.frame.createWindow(system_owner, width / 4, height / 4, @max(@as(usize, 1), width / 2), @max(@as(usize, 1), height / 3));
    }

    pub fn init(width: usize, height: usize, palette: renderer.Palette) !Desktop {
        if (width == 0 or height == 0) return error.InvalidGeometry;
        var desktop: Desktop = undefined;
        desktop.frame = frame_mod.Frame.init(palette);
        try desktop.frame.session_state.registerClient(system_owner);
        desktop.back = try desktop.frame.createWindow(system_owner, width / 8, height / 8, @max(@as(usize, 1), width / 2), @max(@as(usize, 1), height / 2));
        desktop.front = try desktop.frame.createWindow(system_owner, width / 4, height / 4, @max(@as(usize, 1), width / 2), @max(@as(usize, 1), height / 3));
        return desktop;
    }

    pub fn present(self: *Desktop, mapping: bridge.Mapping) bridge.Error!bool {
        return bridge.present(&self.frame, mapping);
    }

    /// Repaint only the old and new front-window footprints. Overlap may be
    /// painted twice; the returned count is framebuffer pixel writes.
    /// A pending full invalidation takes precedence over partial updates.
    pub fn moveFrontAndPresent(self: *Desktop, mapping: bridge.Mapping, x: usize, y: usize) (bridge.Error || wm.Error)!usize {
        var surface = try mapping.surface();
        const slot = self.frame.session_state.windows.slots[self.front.slot];
        if (!slot.occupied or slot.generation != self.front.generation) return error.InvalidHandle;
        const previous = slot.window;
        if (previous.x == x and previous.y == y) {
            return if (self.frame.present(&surface)) surface.width *| surface.height else 0;
        }
        const full_redraw = self.frame.dirty;
        try self.moveFront(x, y);
        if (full_redraw) {
            _ = self.frame.present(&surface);
            return surface.width *| surface.height;
        }
        const old_rect: compositor.Rect = .{ .x = previous.x, .y = previous.y, .width = previous.width, .height = previous.height };
        const new_rect: compositor.Rect = .{ .x = x, .y = y, .width = previous.width, .height = previous.height };
        const pixels = self.frame.presentDirty(&surface, old_rect) +|
            self.frame.presentDirty(&surface, new_rect);
        self.frame.dirty = false;
        return pixels;
    }

    pub fn moveFront(self: *Desktop, x: usize, y: usize) wm.Error!void {
        try self.frame.moveWindow(system_owner, self.front, x, y);
    }
};

test "managed desktop presents, moves and skips unchanged frames" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var desktop = try Desktop.init(8, 8, palette);
    var pixels: [8 * 8 * 4]u8 = @splat(0xaa);
    const mapping: bridge.Mapping = .{
        .bytes = &pixels, .width = 8, .height = 8, .pitch = 32, .bits_per_pixel = 32,
    };
    try std.testing.expect(try desktop.present(mapping));
    try std.testing.expect(!(try desktop.present(mapping)));
    try desktop.moveFront(0, 0);
    try std.testing.expect(try desktop.present(mapping));
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, pixels[0..4]);
    try std.testing.expect(!(try desktop.present(mapping)));
}

test "desktop rejects empty geometry and retains dirty state on bad mapping" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    try std.testing.expectError(error.InvalidGeometry, Desktop.init(0, 8, palette));
    var desktop = try Desktop.init(8, 8, palette);
    var short: [4]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooSmall, desktop.present(.{
        .bytes = &short, .width = 8, .height = 8, .pitch = 32, .bits_per_pixel = 32,
    }));
    try std.testing.expect(desktop.frame.dirty);
}

test "incremental desktop movement matches full composition and preserves unrelated pixels" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var desktop = try Desktop.init(12, 8, palette);
    var pixels: [12 * 8 * 4]u8 = @splat(0);
    const mapping: bridge.Mapping = .{ .bytes = &pixels, .width = 12, .height = 8, .pitch = 48, .bits_per_pixel = 32 };
    try std.testing.expect(try desktop.present(mapping));
    const untouched = pixels[0];
    const positions = [_][2]usize{ .{ 4, 2 }, .{ 0, 0 }, .{ 10, 7 }, .{ 3, 2 } };
    for (positions) |pos| {
        const count = try desktop.moveFrontAndPresent(mapping, pos[0], pos[1]);
        try std.testing.expect(count <= 2 * 6 * 2 + 2 * 6 * 2);
        var expected: [12 * 8 * 4]u8 = @splat(0);
        var surface = try @import("raster.zig").Surface.init(&expected, 12, 8, 48);
        renderer.render(&surface, &desktop.frame.session_state.windows, palette);
        try std.testing.expectEqualSlices(u8, &expected, &pixels);
    }
    _ = untouched;
}

test "invalid mapping does not move desktop window" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var desktop = try Desktop.init(8, 8, palette);
    var short: [4]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooSmall, desktop.moveFrontAndPresent(.{
        .bytes = &short, .width = 8, .height = 8, .pitch = 32, .bits_per_pixel = 32,
    }, 5, 5));
    const slot = desktop.frame.session_state.windows.slots[desktop.front.slot];
    try std.testing.expectEqual(@as(usize, 2), slot.window.x);
}
