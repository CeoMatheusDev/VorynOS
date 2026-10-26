// VorynOS F6: translate absolute pointer samples into frame operations.
//************************************************************************//
//                        This file is part of:                           //
//                              VorynOS                                   //
//             https://github.com/CeoMatheusDev/VorynOS                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 VorynOS - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//
//! The device driver supplies clamped absolute coordinates and button state.
//! This adapter performs edge detection; it does not access hardware.
const std = @import("std");
const frame_mod = @import("frame.zig");
const wm = @import("window_manager.zig");
const session = @import("session.zig");

pub const Input = struct {
    left_pressed: bool = false,

    /// A failed press leaves button state unchanged so it can be retried.
    /// Release always clears capture. Movement without a held button is inert.
    pub fn sample(self: *Input, frame: *frame_mod.Frame, x: usize, y: usize, left: bool) session.Error!bool {
        if (left and !self.left_pressed) {
            const hit = try frame.pointerDown(x, y);
            self.left_pressed = true;
            return hit;
        }
        if (!left and self.left_pressed) {
            frame.pointerUp();
            self.left_pressed = false;
            return false;
        }
        if (left) return try frame.pointerMove(x, y);
        return false;
    }

    pub fn reset(self: *Input, frame: *frame_mod.Frame) void {
        frame.pointerUp();
        self.left_pressed = false;
    }
};

test "pointer samples drag on held button and stop after release" {
    const palette: @import("window_renderer.zig").Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var frame = frame_mod.Frame.init(palette);
    var input = Input{};
    try frame.session_state.registerClient(1);
    const handle = try frame.createWindow(1, 1, 1, 2, 2);
    try std.testing.expect(!(try input.sample(&frame, 0, 0, false)));
    try std.testing.expect(try input.sample(&frame, 1, 1, true));
    try std.testing.expect(try input.sample(&frame, 3, 2, true));
    try std.testing.expectEqual(@as(usize, 3), frame.session_state.windows.slots[handle.slot].window.x);
    try std.testing.expectEqual(@as(usize, 2), frame.session_state.windows.slots[handle.slot].window.y);
    try std.testing.expect(!(try input.sample(&frame, 3, 2, false)));
    try std.testing.expect(!(try input.sample(&frame, 0, 0, false)));
    try std.testing.expectEqual(@as(usize, 3), frame.session_state.windows.slots[handle.slot].window.x);
}

test "rejected button press can be retried and does not capture" {
    const events = @import("event_queue.zig");
    const palette: @import("window_renderer.zig").Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var frame = frame_mod.Frame.init(palette);
    var input = Input{};
    try frame.session_state.registerClient(1);
    const handle = try frame.createWindow(1, 0, 0, 2, 2);
    for (0..events.queue_capacity) |_| try frame.session_state.router.send(1, .{
        .kind = .pointer_move, .window_slot = handle.slot, .window_generation = handle.generation,
    });
    try std.testing.expectError(error.Full, input.sample(&frame, 0, 0, true));
    try std.testing.expect(!input.left_pressed);
    try std.testing.expect(frame.drag == null);
    _ = try frame.session_state.router.receive(1, 1);
    try std.testing.expect(try input.sample(&frame, 0, 0, true));
    try std.testing.expect(input.left_pressed);
    input.reset(&frame);
    try std.testing.expect(!input.left_pressed);
    try std.testing.expect(frame.drag == null);
}
