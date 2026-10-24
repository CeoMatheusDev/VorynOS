// VorynOS F6: bounded per-client graphics event mailbox.
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only
//! Single-threaded queue primitive. Caller must synchronize access across CPUs.
//! No dynamic allocation, hardware access, or unchecked client pointers.
const std = @import("std");

pub const queue_capacity: usize = 64;
pub const Kind = enum(u8) { key_down, key_up, pointer_move, pointer_down, pointer_up, focus_in, focus_out, close };
pub const Event = struct {
    kind: Kind,
    window_slot: u8,
    window_generation: u64,
    data0: i64 = 0,
    data1: i64 = 0,
};
pub const Error = error{ Full, InvalidOwner, NoMailbox, AlreadyRegistered };

const Mailbox = struct {
    active: bool = false,
    owner: u64 = 0,
    head: usize = 0,
    len: usize = 0,
    events: [queue_capacity]Event = undefined,
};

pub const mailbox_capacity: usize = 32;
pub const Router = struct {
    mailboxes: [mailbox_capacity]Mailbox = @splat(.{}),

    /// Registration is explicit: clients cannot consume another process's events.
    pub fn register(self: *Router, owner: u64) Error!void {
        for (&self.mailboxes) |*box| {
            if (box.active and box.owner == owner) return error.AlreadyRegistered;
        }
        for (&self.mailboxes) |*box| {
            if (!box.active) {
                box.* = .{ .active = true, .owner = owner };
                return;
            }
        }
        return error.Full;
    }

    fn find(self: *Router, owner: u64) ?*Mailbox {
        for (&self.mailboxes) |*box| {
            if (box.active and box.owner == owner) return box;
        }
        return null;
    }

    /// Kernel/service sends to the designated owner, never to a client pointer.
    /// On overflow the event is rejected without modifying queue state.
    pub fn send(self: *Router, owner: u64, event: Event) Error!void {
        const box = self.find(owner) orelse return error.NoMailbox;
        if (box.len == queue_capacity) return error.Full;
        const tail = (box.head + box.len) % queue_capacity;
        box.events[tail] = event;
        box.len += 1;
    }

    pub fn receive(self: *Router, caller: u64, owner: u64) Error!?Event {
        if (caller != owner) return error.InvalidOwner;
        const box = self.find(owner) orelse return error.NoMailbox;
        if (box.len == 0) return null;
        const event = box.events[box.head];
        box.head = (box.head + 1) % queue_capacity;
        box.len -= 1;
        return event;
    }

    pub fn unregister(self: *Router, caller: u64, owner: u64) Error!void {
        if (caller != owner) return error.InvalidOwner;
        const box = self.find(owner) orelse return error.NoMailbox;
        box.* = .{};
    }
};

test "FIFO delivery and isolation between process owners" {
    var router = Router{};
    try router.register(11);
    try router.register(22);
    const a: Event = .{ .kind = .key_down, .window_slot = 1, .window_generation = 3, .data0 = 42 };
    const b: Event = .{ .kind = .close, .window_slot = 2, .window_generation = 7 };
    try router.send(11, a);
    try router.send(11, b);
    try std.testing.expectError(error.InvalidOwner, router.receive(22, 11));
    try std.testing.expectEqual(a, (try router.receive(11, 11)).?);
    try std.testing.expectEqual(b, (try router.receive(11, 11)).?);
    try std.testing.expect((try router.receive(11, 11)) == null);
}

test "full queue does not overwrite pending events and wraps correctly" {
    var router = Router{};
    try router.register(1);
    const event: Event = .{ .kind = .pointer_move, .window_slot = 0, .window_generation = 1 };
    for (0..queue_capacity) |_| try router.send(1, event);
    try std.testing.expectError(error.Full, router.send(1, event));
    for (0..queue_capacity / 2) |_| _ = (try router.receive(1, 1)).?;
    for (0..queue_capacity / 2) |_| try router.send(1, event);
    for (0..queue_capacity) |_| try std.testing.expectEqual(event, (try router.receive(1, 1)).?);
    try std.testing.expect((try router.receive(1, 1)) == null);
}

test "registration, teardown and stale events" {
    var router = Router{};
    try router.register(4);
    try std.testing.expectError(error.AlreadyRegistered, router.register(4));
    try router.send(4, .{ .kind = .close, .window_slot = 0, .window_generation = 1 });
    try std.testing.expectError(error.InvalidOwner, router.unregister(5, 4));
    try router.unregister(4, 4);
    try std.testing.expectError(error.NoMailbox, router.receive(4, 4));
    try router.register(4);
    try std.testing.expect((try router.receive(4, 4)) == null);
}
