//************************************************************************//
//  keyboard_motion.zig                                                   //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! F6.8: deslocamento de janelas por setas PS/2 set 1.
//! Política pura: não acessa MMIO, não aloca, não altera z-order.

const std = @import("std");
const keyboard = @import("voryn_keyboard");
const compositor = @import("compositor.zig");

pub fn move(window: *compositor.Window, bounds: compositor.Rect, event: keyboard.KeyEvent, step: usize) bool {
    if (!event.pressed or !event.extended or step == 0) return false;
    const max_x = bounds.width -| window.width;
    const max_y = bounds.height -| window.height;
    const old_x = window.x;
    const old_y = window.y;
    switch (event.scancode) {
        0x4b => window.x = window.x -| step, // left
        0x4d => window.x = @min(max_x, window.x +| step), // right
        0x48 => window.y = window.y -| step, // up
        0x50 => window.y = @min(max_y, window.y +| step), // down
        else => return false,
    }
    window.x = @min(max_x, window.x);
    window.y = @min(max_y, window.y);
    return window.x != old_x or window.y != old_y;
}

test "right arrow moves within bounds, release and ordinary keys ignored" {
    var window: compositor.Window = .{ .x = 2, .y = 2, .width = 3, .height = 3, .color = .{ 1, 2, 3, 0 } };
    const bounds: compositor.Rect = .{ .x = 0, .y = 0, .width = 8, .height = 8 };
    try std.testing.expect(!move(&window, bounds, .{ .scancode = 0x4d, .extended = true, .pressed = false }, 2));
    try std.testing.expect(!move(&window, bounds, .{ .scancode = 0x1e, .extended = false, .pressed = true }, 2));
    try std.testing.expect(move(&window, bounds, .{ .scancode = 0x4d, .extended = true, .pressed = true }, 2));
    try std.testing.expectEqual(@as(usize, 4), window.x);
    try std.testing.expect(move(&window, bounds, .{ .scancode = 0x4d, .extended = true, .pressed = true }, 2));
    try std.testing.expectEqual(@as(usize, 5), window.x);
    try std.testing.expect(!move(&window, bounds, .{ .scancode = 0x4d, .extended = true, .pressed = true }, 2));
}

test "left up and down clamp to framebuffer" {
    var window: compositor.Window = .{ .x = 1, .y = 1, .width = 2, .height = 2, .color = .{ 0, 0, 0, 0 } };
    const bounds: compositor.Rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 };
    try std.testing.expect(move(&window, bounds, .{ .scancode = 0x4b, .extended = true, .pressed = true }, 8));
    try std.testing.expectEqual(@as(usize, 0), window.x);
    try std.testing.expect(move(&window, bounds, .{ .scancode = 0x48, .extended = true, .pressed = true }, 8));
    try std.testing.expectEqual(@as(usize, 0), window.y);
    try std.testing.expect(move(&window, bounds, .{ .scancode = 0x50, .extended = true, .pressed = true }, 8));
    try std.testing.expectEqual(@as(usize, 2), window.y);
}
