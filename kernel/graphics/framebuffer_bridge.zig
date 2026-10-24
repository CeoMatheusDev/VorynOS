// VorynOS F7: bounded framebuffer presentation bridge.
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only
//! The caller provides an already mapped and authorized byte slice.
//! This module never dereferences firmware physical addresses.
const std = @import("std");
const raster = @import("raster.zig");
const frame_mod = @import("frame.zig");

pub const Error = error{ InvalidGeometry, UnsupportedFormat, BufferTooSmall };

pub const Mapping = struct {
    bytes: []u8,
    width: usize,
    height: usize,
    pitch: usize,
    bits_per_pixel: u32,

    /// Validates a 32-bit packed-pixel framebuffer before any write.
    pub fn surface(self: Mapping) Error!raster.Surface {
        if (self.bits_per_pixel != 32) return error.UnsupportedFormat;
        if (self.width == 0 or self.height == 0) return error.InvalidGeometry;
        const row_bytes = std.math.mul(usize, self.width, 4) catch return error.InvalidGeometry;
        if (self.pitch < row_bytes) return error.InvalidGeometry;
        // Only the visible bytes of the final row must be mapped.
        // Delegate stride/overflow checks to the canonical raster validator.
        return raster.Surface.init(self.bytes, self.width, self.height, self.pitch) catch |err| switch (err) {
            error.BufferTooSmall => error.BufferTooSmall,
            error.InvalidGeometry => error.InvalidGeometry,
            error.UnsupportedFormat => error.UnsupportedFormat,
        };
    }
};

/// Return false when no new frame needs to be presented.
pub fn present(frame: *frame_mod.Frame, mapping: Mapping) Error!bool {
    var surface = try mapping.surface();
    return frame.present(&surface);
}

test "mapped framebuffer presents a window and skips unchanged frames" {
    const palette: @import("window_renderer.zig").Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 8, 8, 8, 8 },
        .inactive = .{ 2, 2, 2, 2 },
    };
    var frame = frame_mod.Frame.init(palette);
    try frame.session_state.registerClient(1);
    _ = try frame.createWindow(1, 0, 0, 1, 1);
    var bytes: [48]u8 = @splat(0xaa);
    const mapping: Mapping = .{
        .bytes = &bytes, .width = 2, .height = 2, .pitch = 12, .bits_per_pixel = 32,
    };
    try std.testing.expect(try present(&frame, mapping));
    try std.testing.expectEqualSlices(u8, &.{ 8, 8, 8, 8 }, bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[8]);
    try std.testing.expect(!(try present(&frame, mapping)));
}

test "last-row padding is optional but visible pixels are mandatory" {
    const palette: @import("window_renderer.zig").Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 7, 7, 7, 7 },
        .inactive = .{ 2, 2, 2, 2 },
    };
    var frame = frame_mod.Frame.init(palette);
    try frame.session_state.registerClient(1);
    _ = try frame.createWindow(1, 0, 1, 2, 1);
    // 2 rows, pitch 12, visible row 8: 12 + 8 = 20 bytes.
    var pixels: [20]u8 = @splat(0xaa);
    const mapping: Mapping = .{
        .bytes = &pixels, .width = 2, .height = 2, .pitch = 12, .bits_per_pixel = 32,
    };
    try std.testing.expect(try present(&frame, mapping));
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 7 }, pixels[12..16]);
    try std.testing.expectEqual(@as(u8, 0xaa), pixels[8]);
    frame.invalidate();
    try std.testing.expectError(error.BufferTooSmall, present(&frame, .{
        .bytes = pixels[0..19], .width = 2, .height = 2, .pitch = 12, .bits_per_pixel = 32,
    }));
    try std.testing.expect(frame.dirty);
}

test "invalid framebuffer mapping does not consume a pending frame" {
    const palette: @import("window_renderer.zig").Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 8, 8, 8, 8 },
        .inactive = .{ 2, 2, 2, 2 },
    };
    var frame = frame_mod.Frame.init(palette);
    // Two rows with an 8-byte pitch require 16 bytes; provide one less.
    var bytes: [15]u8 = @splat(0xaa);
    const mapping: Mapping = .{
        .bytes = &bytes, .width = 2, .height = 2, .pitch = 8, .bits_per_pixel = 32,
    };
    try std.testing.expectError(error.BufferTooSmall, present(&frame, mapping));
    try std.testing.expect(frame.dirty);
    try std.testing.expectError(error.UnsupportedFormat, (Mapping{
        .bytes = &bytes, .width = 2, .height = 2, .pitch = 8, .bits_per_pixel = 16,
    }).surface());
    try std.testing.expectError(error.InvalidGeometry, (Mapping{
        .bytes = &bytes, .width = 2, .height = 2, .pitch = 4, .bits_per_pixel = 32,
    }).surface());
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
}
