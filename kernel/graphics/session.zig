// VorynOS F6: graphics session joins window management and event delivery.
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
//! Pure host-testable routing. The caller serializes access and validates
//! process identity at the syscall boundary; this module owns no user pointers.
const std = @import("std");
const wm = @import("window_manager.zig");
const events = @import("event_queue.zig");

pub const Error = wm.Error || events.Error;
pub const Session = struct {
    windows: wm.Manager = .{},
    router: events.Router = .{},

    pub fn registerClient(self: *Session, process: u64) events.Error!void {
        try self.router.register(process);
    }

    pub fn createWindow(self: *Session, process: u64, x: usize, y: usize, width: usize, height: usize) Error!wm.Handle {
        // A mailbox is mandatory before a process can receive input.
        var registered = false;
        for (&self.router.mailboxes) |*box| {
            if (box.active and box.owner == process) {
                registered = true;
                break;
            }
        }
        if (!registered) return error.NoMailbox;
        return self.windows.create(.{ .owner = process, .x = x, .y = y, .width = width, .height = height });
    }

    /// Route a pointer click to the uppermost visible window.
    /// Return false for clicks outside windows; full queues report an error.
    pub fn pointerDown(self: *Session, x: usize, y: usize) Error!bool {
        const handle = self.windows.hitTest(x, y) orelse return false;
        const slot = &self.windows.slots[handle.slot];
        const owner = slot.window.owner;
        const dx = x - slot.window.x;
        const dy = y - slot.window.y;
        // Saturate at i64 max to avoid signed integer traps on large coordinates.
        const max: usize = @intCast(std.math.maxInt(i64));
        try self.router.send(owner, .{
            .kind = .pointer_down,
            .window_slot = handle.slot,
            .window_generation = handle.generation,
            .data0 = @intCast(@min(dx, max)),
            .data1 = @intCast(@min(dy, max)),
        });
        // Commit focus/z-order only after delivery succeeds. A full mailbox
        // must not change the visible window order or keyboard recipient.
        try self.windows.raise(handle, owner);
        return true;
    }

    /// Keyboard input is delivered exclusively to the currently focused window.
    /// The generation tag allows consumers to reject events from destroyed windows.
    pub fn keyEvent(self: *Session, pressed: bool, keycode: u32) events.Error!bool {
        const handle = self.windows.focused orelse return false;
        const slot = &self.windows.slots[handle.slot];
        if (!slot.occupied or !slot.window.visible or slot.generation != handle.generation) return false;
        try self.router.send(slot.window.owner, .{
            .kind = if (pressed) .key_down else .key_up,
            .window_slot = handle.slot,
            .window_generation = handle.generation,
            .data0 = @intCast(keycode),
        });
        return true;
    }

    /// Only the owner can destroy a window; old queued events remain tagged
    /// with the old generation so consumers can discard them safely.
    pub fn destroyWindow(self: *Session, process: u64, handle: wm.Handle) wm.Error!void {
        try self.windows.destroy(handle, process);
    }
};

test "pointer routing follows z-order and isolates client queues" {
    var s = Session{};
    try s.registerClient(10);
    try s.registerClient(20);
    const bottom = try s.createWindow(10, 0, 0, 10, 10);
    const top = try s.createWindow(20, 3, 3, 5, 5);
    try std.testing.expect(try s.pointerDown(4, 4));
    try std.testing.expect((try s.router.receive(10, 10)) == null);
    const click = (try s.router.receive(20, 20)).?;
    try std.testing.expectEqual(events.Kind.pointer_down, click.kind);
    try std.testing.expectEqual(top.slot, click.window_slot);
    try std.testing.expectEqual(@as(i64, 1), click.data0);
    try std.testing.expectEqual(@as(i64, 1), click.data1);
    try s.windows.raise(bottom, 10);
    try std.testing.expect(try s.pointerDown(4, 4));
    try std.testing.expectEqual(bottom.slot, (try s.router.receive(10, 10)).?.window_slot);
    try std.testing.expect(!(try s.pointerDown(999, 999)));
}

test "unregistered clients and foreign window deletion fail" {
    var s = Session{};
    try std.testing.expectError(error.NoMailbox, s.createWindow(1, 0, 0, 1, 1));
    try s.registerClient(1);
    const handle = try s.createWindow(1, 0, 0, 1, 1);
    try std.testing.expectError(error.InvalidHandle, s.destroyWindow(2, handle));
    try s.destroyWindow(1, handle);
    try std.testing.expect(!(try s.pointerDown(0, 0)));
}

test "keyboard events follow focus and do not leak to other clients" {
    var s = Session{};
    try s.registerClient(11);
    try s.registerClient(22);
    const first = try s.createWindow(11, 0, 0, 10, 10);
    const second = try s.createWindow(22, 0, 0, 10, 10);
    try std.testing.expect(try s.keyEvent(true, 30));
    try std.testing.expect((try s.router.receive(11, 11)) == null);
    const down = (try s.router.receive(22, 22)).?;
    try std.testing.expectEqual(events.Kind.key_down, down.kind);
    try std.testing.expectEqual(second.generation, down.window_generation);
    try std.testing.expectEqual(@as(i64, 30), down.data0);
    try s.windows.raise(first, 11);
    try std.testing.expect(try s.keyEvent(false, 30));
    const up = (try s.router.receive(11, 11)).?;
    try std.testing.expectEqual(events.Kind.key_up, up.kind);
    try std.testing.expectEqual(first.slot, up.window_slot);
    try s.destroyWindow(11, first);
    try s.destroyWindow(22, second);
    try std.testing.expect(!(try s.keyEvent(true, 30)));
}

test "keyboard delivery rejects full mailbox without changing focus" {
    var s = Session{};
    try s.registerClient(7);
    const window = try s.createWindow(7, 0, 0, 1, 1);
    for (0..events.queue_capacity) |_| try std.testing.expect(try s.keyEvent(true, 1));
    try std.testing.expectError(error.Full, s.keyEvent(false, 1));
    try std.testing.expectEqual(window, s.windows.focused.?);
}

test "pointer click activates underlying window for subsequent keyboard input" {
    var s = Session{};
    try s.registerClient(1);
    try s.registerClient(2);
    const bottom = try s.createWindow(1, 0, 0, 8, 8);
    const top = try s.createWindow(2, 4, 4, 8, 8);
    try std.testing.expectEqual(top, s.windows.focused.?);
    try std.testing.expect(try s.pointerDown(1, 1));
    try std.testing.expectEqual(bottom, s.windows.focused.?);
    try std.testing.expect(try s.keyEvent(true, 42));
    try std.testing.expectEqual(events.Kind.pointer_down, (try s.router.receive(1, 1)).?.kind);
    const key = (try s.router.receive(1, 1)).?;
    try std.testing.expectEqual(events.Kind.key_down, key.kind);
    try std.testing.expectEqual(bottom.slot, key.window_slot);
    try std.testing.expect((try s.router.receive(2, 2)) == null);
    try std.testing.expectEqual(bottom, s.windows.hitTest(5, 5).?);
}

test "full click queue preserves focus and stacking order" {
    var s = Session{};
    try s.registerClient(1);
    try s.registerClient(2);
    const bottom = try s.createWindow(1, 0, 0, 8, 8);
    const top = try s.createWindow(2, 4, 4, 8, 8);
    for (0..events.queue_capacity) |_| try s.router.send(1, .{
        .kind = .pointer_move, .window_slot = bottom.slot, .window_generation = bottom.generation,
    });
    try std.testing.expectError(error.Full, s.pointerDown(1, 1));
    try std.testing.expectEqual(top, s.windows.focused.?);
    try std.testing.expectEqual(top, s.windows.hitTest(5, 5).?);
}
