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
    pub const StageTiming = struct {
        movement_cycles: u64 = 0,
        composition_cycles: u64 = 0,
        geometry_cycles: u64 = 0,
        paint_cycles: u64 = 0,
    };

    pub fn moveFrontAndPresent(self: *Desktop, mapping: bridge.Mapping, x: usize, y: usize) (bridge.Error || wm.Error)!usize {
        return self.moveFrontAndPresentTimed(mapping, x, y, null, null);
    }

    /// Optional timestamp hook keeps the compositor platform-independent.
    /// Timings cover window state mutation and dirty-region presentation.
    pub fn moveFrontAndPresentTimed(
        self: *Desktop,
        mapping: bridge.Mapping,
        x: usize,
        y: usize,
        clock: ?*const fn () u64,
        timing: ?*StageTiming,
    ) (bridge.Error || wm.Error)!usize {
        if (timing) |result| result.* = .{};
        var surface = try mapping.surface();
        const slot = self.frame.session_state.windows.slots[self.front.slot];
        if (!slot.occupied or slot.generation != self.front.generation) return error.InvalidHandle;
        const previous = slot.window;
        if (previous.x == x and previous.y == y) {
            return if (self.frame.present(&surface)) surface.width *| surface.height else 0;
        }
        const full_redraw = self.frame.dirty;
        const movement_start: u64 = if (clock) |read| read() else 0;
        try self.moveFront(x, y);
        const movement_end: u64 = if (clock) |read| read() else 0;
        if (timing) |result| result.movement_cycles = movement_end - movement_start;
        const composition_start: u64 = if (clock) |read| read() else 0;
        if (full_redraw) {
            _ = self.frame.present(&surface);
            if (timing) |result| result.composition_cycles = if (clock) |read| read() - composition_start else 0;
            return surface.width *| surface.height;
        }
        const old_rect: compositor.Rect = .{ .x = previous.x, .y = previous.y, .width = previous.width, .height = previous.height };
        const new_rect: compositor.Rect = .{ .x = x, .y = y, .width = previous.width, .height = previous.height };
        // Paint the old footprint excluding its overlap with the new one.
        // The new footprint is painted once, so overlapping pixels are not
        // written twice. Clip before calculating endpoints to avoid overflow.
        const ox = @min(old_rect.x, surface.width);
        const oy = @min(old_rect.y, surface.height);
        const oright = ox + @min(old_rect.width, surface.width - ox);
        const obottom = oy + @min(old_rect.height, surface.height - oy);
        const nx = @min(new_rect.x, surface.width);
        const ny = @min(new_rect.y, surface.height);
        const nright = nx + @min(new_rect.width, surface.width - nx);
        const nbottom = ny + @min(new_rect.height, surface.height - ny);
        const ix = @max(ox, nx);
        const iy = @max(oy, ny);
        const iright = @min(oright, nright);
        const ibottom = @min(obottom, nbottom);
        const paint_start: u64 = if (clock) |read| read() else 0;
        if (timing) |result| result.geometry_cycles = paint_start - composition_start;
        var pixels: usize = 0;
        if (ix < iright and iy < ibottom) {
            pixels +|= self.frame.presentDirty(&surface, .{ .x = ox, .y = oy, .width = oright - ox, .height = iy - oy });
            pixels +|= self.frame.presentDirty(&surface, .{ .x = ox, .y = ibottom, .width = oright - ox, .height = obottom - ibottom });
            pixels +|= self.frame.presentDirty(&surface, .{ .x = ox, .y = iy, .width = ix - ox, .height = ibottom - iy });
            pixels +|= self.frame.presentDirty(&surface, .{ .x = iright, .y = iy, .width = oright - iright, .height = ibottom - iy });
        } else {
            pixels +|= self.frame.presentDirty(&surface, old_rect);
        }
        pixels +|= self.frame.presentDirty(&surface, new_rect);
        self.frame.dirty = false;
        const paint_end: u64 = if (clock) |read| read() else 0;
        if (timing) |result| {
            result.paint_cycles = paint_end - paint_start;
            result.composition_cycles = paint_end - composition_start;
        }
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

test "overlapping movement paints each pixel at most once" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var desktop = try Desktop.init(32, 24, palette);
    var pixels: [32 * 24 * 4]u8 = @splat(0);
    const mapping: bridge.Mapping = .{ .bytes = &pixels, .width = 32, .height = 24, .pitch = 128, .bits_per_pixel = 32 };
    try std.testing.expect(try desktop.present(mapping));
    // Front footprint is 16x8. Moving one pixel horizontally yields
    // a union of 17x8, rather than the former 32x8 writes.
    const writes = try desktop.moveFrontAndPresent(mapping, 9, 6);
    try std.testing.expectEqual(@as(usize, 17 * 8), writes);
    var expected: [32 * 24 * 4]u8 = @splat(0);
    var surface = try @import("raster.zig").Surface.init(&expected, 32, 24, 128);
    renderer.render(&surface, &desktop.frame.session_state.windows, palette);
    try std.testing.expectEqualSlices(u8, &expected, &pixels);
}
