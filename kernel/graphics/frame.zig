// VorynOS F6: deterministic input-to-frame rendering coordinator.
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only
//! Caller owns synchronization and the mapped surface. No heap allocations.
const std = @import("std");
const session = @import("session.zig");
const renderer = @import("window_renderer.zig");
const raster = @import("raster.zig");
const compositor = @import("compositor.zig");
const wm = @import("window_manager.zig");

pub const Frame = struct {
    session_state: session.Session = .{},
    palette: renderer.Palette,
    dirty: bool = true,

    pub fn init(palette: renderer.Palette) Frame {
        return .{ .palette = palette };
    }

    /// Only a delivered click changes focus and invalidates the framebuffer.
    pub fn pointerDown(self: *Frame, x: usize, y: usize) session.Error!bool {
        const previous = self.session_state.windows.focused;
        const hit = try self.session_state.pointerDown(x, y);
        if (hit and (previous == null or !std.meta.eql(previous.?, self.session_state.windows.focused.?))) {
            self.dirty = true;
        }
        return hit;
    }

    pub fn createWindow(self: *Frame, owner: u64, x: usize, y: usize, width: usize, height: usize) session.Error!wm.Handle {
        const handle = try self.session_state.createWindow(owner, x, y, width, height);
        self.dirty = true;
        return handle;
    }

    pub fn destroyWindow(self: *Frame, owner: u64, handle: wm.Handle) wm.Error!void {
        try self.session_state.destroyWindow(owner, handle);
        self.dirty = true;
    }

    /// Move an owned window; redraw both its previous and new locations.
    pub fn moveWindow(self: *Frame, owner: u64, handle: wm.Handle, x: usize, y: usize) wm.Error!void {
        if (handle.slot >= wm.capacity) return error.InvalidHandle;
        const slot = &self.session_state.windows.slots[handle.slot];
        if (!slot.occupied or slot.generation != handle.generation or handle.generation == 0 or slot.window.owner != owner)
            return error.InvalidHandle;
        if (slot.window.x == x and slot.window.y == y) return;
        try self.session_state.windows.move(handle, owner, x, y);
        self.dirty = true;
    }

    /// Returns false if nothing changed; the caller can skip presenting a frame.
    pub fn present(self: *Frame, surface: *raster.Surface) bool {
        if (!self.dirty) return false;
        renderer.render(surface, &self.session_state.windows, self.palette);
        self.dirty = false;
        return true;
    }

    /// Explicit invalidation for driver/surface changes.
    pub fn invalidate(self: *Frame) void {
        self.dirty = true;
    }

    pub fn presentDirty(self: *Frame, surface: *raster.Surface, rect: compositor.Rect) usize {
        // Explicit dirty rendering does not consume a pending full redraw.
        return renderer.renderDirty(surface, &self.session_state.windows, self.palette, rect);
    }
};

test "click changes focus and redraws only when necessary" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 2, 2, 2, 2 },
    };
    var frame = Frame.init(palette);
    try frame.session_state.registerClient(1);
    try frame.session_state.registerClient(2);
    _ = try frame.createWindow(1, 0, 0, 3, 3);
    _ = try frame.createWindow(2, 2, 2, 2, 2);
    var pixels: [64]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    try std.testing.expect(frame.present(&surface));
    try std.testing.expect(!frame.present(&surface));
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2 }, pixels[0..4]);
    try std.testing.expect(try frame.pointerDown(0, 0));
    try std.testing.expect(frame.present(&surface));
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, pixels[0..4]);
    try std.testing.expect(!frame.present(&surface));
    try std.testing.expect(!(try frame.pointerDown(99, 99)));
    try std.testing.expect(!frame.present(&surface));
}

test "rejected click does not invalidate frame" {
    const events = @import("event_queue.zig");
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 2, 2, 2, 2 },
    };
    var frame = Frame.init(palette);
    try frame.session_state.registerClient(1);
    try frame.session_state.registerClient(2);
    const bottom = try frame.createWindow(1, 0, 0, 3, 3);
    _ = try frame.createWindow(2, 2, 2, 2, 2);
    var pixels: [64]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    _ = frame.present(&surface);
    for (0..events.queue_capacity) |_| try frame.session_state.router.send(1, .{
        .kind = .pointer_move, .window_slot = bottom.slot, .window_generation = bottom.generation,
    });
    try std.testing.expectError(error.Full, frame.pointerDown(0, 0));
    try std.testing.expect(!frame.present(&surface));
}

test "window movement invalidates old and new pixels and checks ownership" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 7, 7, 7, 7 },
        .inactive = .{ 2, 2, 2, 2 },
    };
    var frame = Frame.init(palette);
    try frame.session_state.registerClient(1);
    const handle = try frame.createWindow(1, 0, 0, 1, 1);
    var pixels: [64]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    try std.testing.expect(frame.present(&surface));
    try std.testing.expectError(error.InvalidHandle, frame.moveWindow(2, handle, 2, 2));
    try std.testing.expect(!frame.present(&surface));
    try frame.moveWindow(1, handle, 0, 0);
    try std.testing.expect(!frame.present(&surface));
    try frame.moveWindow(1, handle, 2, 2);
    try std.testing.expect(frame.present(&surface));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 7 }, pixels[40..44]);
    try frame.destroyWindow(1, handle);
    try std.testing.expectError(error.InvalidHandle, frame.moveWindow(1, handle, 1, 1));
    try std.testing.expect(frame.present(&surface));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[40..44]);
}
