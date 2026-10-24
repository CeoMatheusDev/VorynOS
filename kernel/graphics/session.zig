// VorynOS F6: graphics session joins window management and event delivery.
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only
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
    pub fn pointerDown(self: *Session, x: usize, y: usize) events.Error!bool {
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
