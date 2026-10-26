//************************************************************************//
//  channel.zig                                                           //
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

//! The channel of the VNX: the queue of messages between two tasks.
//!
//! The mechanism is in the kernel: the channel is a pair of queues, one
//! for each side, and the messages leave the queue in the order they
//! entered it. The policy is not: the kernel does not decide what a
//! message means, and the service that owns the channel decides.
//!
//! The two queues matter: a channel with a single queue would deliver a
//! message to whoever asks first, and the task that sent the message
//! would take it back. Each side has its own queue, and a message sent
//! by one side waits in the queue of the other side.
//!
//! The channel does not block on its own. A task that asks for a message
//! with the call of the queue and finds it empty receives the error of the
//! empty queue, and asks again. A task that does not want to ask again
//! registers itself as a waiter of the side with the call of the blocking
//! receive: the message that arrives is delivered directly to the task, and
//! the kernel wakes it up.

const std = @import("std");

const context = @import("../task/context.zig");

/// A message of a channel.
///
/// The message has a type and a value. The type lets the receiver tell
/// which message it received, and the value carries the data of the
/// message. The two fields are enough for the first increment, and the
/// shape can grow with the contract of the channel.
pub const Message = extern struct {
    /// The type of the message.
    kind: u64 = 0,
    /// The value of the message.
    value: u64 = 0,
};

/// The number of messages that a queue holds.
pub const capacity = 16;

/// The number of channels that the kernel has.
pub const count = 4;

/// The sides of a channel.
///
/// The user mode is the first side and the kernel is the second one. A
/// message sent by one side waits in the queue of the other side.
pub const Side = struct {
    /// The side of the user mode.
    pub const user: u64 = 0;
    /// The side of the kernel.
    pub const kernel: u64 = 1;
};

/// A task that waits for a message of a queue.
///
/// The waiter carries the address of the two words where the result of the
/// call is written, and the address of the task that waits. The delivery
/// writes the result **straight** into the context saved of the task, and
/// therefore the caller of the channel does not need to know anything
/// about the scheduler.
pub const Waiter = struct {
    /// The address where the type of the message is written.
    kind: *u64,
    /// The address where the value of the message is written.
    value: *u64,
    /// The task that waits, given back to the routine that wakes it.
    task: *anyopaque,
    /// The routine that makes the task ready again.
    wake: *const fn (task: *anyopaque) void,
    /// The deadline of the wait, in ticks of the timer.
    ///
    /// Zero means that the wait does not expire: the task waits until the
    /// message arrives, or until the wait is cancelled.
    deadline: u64 = 0,
};

/// The number of tasks that can wait in the same queue.
pub const waiter_capacity = 8;

/// A queue of messages.
pub const Queue = struct {
    /// The messages of the queue, in the order they were sent.
    messages: [capacity]Message = @splat(.{}),
    /// The place of the first message of the queue.
    head: u32 = 0,
    /// The number of messages in the queue.
    length: u32 = 0,
    /// The number of messages that were sent.
    sent: u64 = 0,
    /// The number of messages that were received.
    received: u64 = 0,
    /// The number of messages that did not fit in the queue.
    refused: u64 = 0,
    /// The moment of the last message that was sent.
    ///
    /// The counter of time lets the kernel measure the latency of the
    /// delivery: the interval between the message leaving and the message
    /// arriving.
    sent_at: u64 = 0,
    /// The tasks that wait for a message of this queue.
    waiters: [waiter_capacity]?Waiter = @splat(null),
    /// The number of messages that were delivered to a task that was
    /// waiting.
    delivered: u64 = 0,
    /// The moment of the last message that was delivered to a task that
    /// was waiting.
    ///
    /// The value is what allows the measurement of the real delivery
    /// latency: the
    /// interval between the message leaving and the message arriving.
    delivered_at: u64 = 0,
    /// The number of waits of this queue that expired without a message.
    expired: u64 = 0,

    /// Puts a message in the queue.
    ///
    /// The function returns false when the queue is full, and the message
    /// is not lost silently: the counter of the refused messages grows.
    pub fn send(self: *Queue, message: Message) bool {
        if (self.length == capacity) {
            self.refused += 1;
            return false;
        }

        const tail = (self.head + self.length) % capacity;
        self.messages[tail] = message;
        self.length += 1;
        self.sent += 1;
        return true;
    }

    /// Registers a task that waits for a message of the queue.
    ///
    /// The task that waits is woken by the message that arrives, and the
    /// message does not stay in the queue: it is delivered straight to the
    /// context of the task.
    ///
    /// The function returns false when the queue already holds the
    /// maximum number of
    /// tasks waiting.
    pub fn wait(self: *Queue, waiter: Waiter) bool {
        for (&self.waiters) |*entry| {
            if (entry.* != null) continue;
            entry.* = waiter;
            return true;
        }
        return false;
    }

    /// Removes a wait of a task, without delivering any message.
    ///
    /// The function returns true when the wait existed.
    pub fn cancelWait(self: *Queue, waiter: Waiter) bool {
        for (&self.waiters) |*entry| {
            const value = entry.* orelse continue;
            if (value.task != waiter.task) continue;
            entry.* = null;
            return true;
        }
        return false;
    }

    /// Delivers a message to a task that waits, if there is one.
    ///
    /// The function returns true when the message was delivered, and false
    /// when there was no task waiting, and the message has to go to the
    /// queue.
    pub fn deliver(self: *Queue, message: Message) bool {
        for (&self.waiters) |*entry| {
            const waiter = entry.* orelse continue;

            // The result of the call is written straight into the context
            // saved of the
            // task, and the task continues after the call, as if the call
            // had answered at once.
            waiter.kind.* = message.kind;
            waiter.value.* = message.value;
            entry.* = null;

            // The task that was woken is chosen by the scheduler, and the
            // delivery
            // records the moment the message arrived.
            self.delivered += 1;
            self.delivered_at = context.timestamp();
            waiter.wake(waiter.task);
            return true;
        }
        return false;
    }

    /// Expires the waits whose deadline has passed.
    ///
    /// The wait is removed from the queue, the result of the call is
    /// written in the context of the task — the value is zero, because no
    /// message arrived — and the task is woken. The message that arrives
    /// later stays in the queue, for the next call.
    ///
    /// A wait without a deadline never expires. The function returns the
    /// number of waits that expired.
    pub fn expire(self: *Queue, now: u64, result: u64) u32 {
        var expired_waits: u32 = 0;

        for (&self.waiters) |*entry| {
            const waiter = entry.* orelse continue;
            if (waiter.deadline == 0) continue;
            if (now < waiter.deadline) continue;

            waiter.kind.* = result;
            waiter.value.* = 0;
            entry.* = null;

            self.expired += 1;
            expired_waits += 1;
            waiter.wake(waiter.task);
        }

        return expired_waits;
    }

    /// The number of waits of this queue that expired.
    pub fn expirations(self: *const Queue) u64 {
        return self.expired;
    }

    /// Takes a message from the queue.
    ///
    /// The function returns null when the queue is empty.
    pub fn receive(self: *Queue) ?Message {
        if (self.length == 0) return null;

        const message = self.messages[self.head];
        self.head = (self.head + 1) % capacity;
        self.length -= 1;
        self.received += 1;
        return message;
    }

    /// The number of messages waiting in the queue.
    pub fn pending(self: *const Queue) u32 {
        return self.length;
    }

    /// Checks whether the queue is empty.
    pub fn isEmpty(self: *const Queue) bool {
        return self.length == 0;
    }

    /// The number of cycles between the last message that was sent and
    /// the moment of the call.
    ///
    /// The value is the latency of the delivery, and the kernel reports it
    /// when the message arrives.
    pub fn latency(self: *const Queue) u64 {
        return context.timestamp() - self.sent_at;
    }
};

/// A channel of messages between two tasks.
pub const Channel = struct {
    /// The identifier of the channel.
    id: u32 = 0,
    /// The queue of each side of the channel.
    queues: [2]Queue = @splat(.{}),

    /// Registers a task that waits for a message of one side.
    ///
    /// The function returns false when the side does not exist, or when its
    /// queue already holds the maximum number of tasks waiting.
    pub fn wait(self: *Channel, side: u64, waiter: Waiter) bool {
        if (side >= self.queues.len) return false;
        return self.queues[side].wait(waiter);
    }

    /// Removes the wait of a task on one side.
    pub fn cancelWait(self: *Channel, side: u64, waiter: Waiter) bool {
        if (side >= self.queues.len) return false;
        return self.queues[side].cancelWait(waiter);
    }

    /// Delivers a message to a task that waits on one side.
    ///
    /// The function returns true when the message was delivered, and the
    /// message does not stay in the queue.
    pub fn deliver(self: *Channel, side: u64, message: Message) bool {
        if (side >= self.queues.len) return false;
        return self.queues[side].deliver(message);
    }

    /// Expires the waits of one side whose deadline has passed.
    pub fn expire(self: *Channel, side: u64, now: u64, result: u64) u32 {
        if (side >= self.queues.len) return 0;
        return self.queues[side].expire(now, result);
    }

    /// The number of waits of one side that expired.
    pub fn expirations(self: *const Channel, side: u64) u64 {
        if (side >= self.queues.len) return 0;
        return self.queues[side].expirations();
    }

    /// Delivers a message to a task that waits, or puts it in the queue.
    ///
    /// The function is the single path of a message that leaves, and
    /// therefore it is the one that marks the moment of the departure: the
    /// delivery latency is the interval between that moment and the moment
    /// the message arrived at the
    /// task that was waiting.
    pub fn post(self: *Channel, side: u64, message: Message) bool {
        if (side >= self.queues.len) return false;

        const queue = &self.queues[side];
        queue.sent_at = context.timestamp();

        if (queue.deliver(message)) return true;
        return queue.send(message);
    }

    /// The number of messages that arrived at a task that was waiting.
    pub fn deliveries(self: *Channel, side: u64) u64 {
        if (side >= self.queues.len) return 0;
        return self.queues[side].delivered;
    }

    /// The number of cycles between the message leaving and the message
    /// arriving.
    ///
    /// The measured latency is the one of the delivery: the interval
    /// between the moment the message was posted in the queue and the moment
    /// it arrived at the
    /// task that was waiting.
    pub fn deliveryLatency(self: *Channel, side: u64) u64 {
        if (side >= self.queues.len) return 0;
        const queue = &self.queues[side];
        if (queue.delivered_at == 0) return 0;
        return queue.delivered_at - queue.sent_at;
    }

    /// Puts a message in the queue of a side.
    ///
    /// The function returns false when the queue is full.
    pub fn sendTo(self: *Channel, side: u64, message: Message) bool {
        if (side >= self.queues.len) return false;
        return self.queues[side].send(message);
    }

    /// Takes a message from the queue of a side.
    ///
    /// The function returns null when the queue is empty.
    pub fn receiveFrom(self: *Channel, side: u64) ?Message {
        if (side >= self.queues.len) return null;
        return self.queues[side].receive();
    }

    /// Checks whether the queue of a side is empty.
    pub fn isEmpty(self: *const Channel, side: u64) bool {
        if (side >= self.queues.len) return true;
        return self.queues[side].isEmpty();
    }

    /// The number of cycles between the last message that was sent to a
    /// side and the moment of the call.
    pub fn latency(self: *const Channel, side: u64) u64 {
        if (side >= self.queues.len) return 0;
        return self.queues[side].latency();
    }
};

/// The channels of the kernel.
var channels: [count]Channel = @splat(.{});

/// The channel with the given identifier.
///
/// The function returns null when the identifier does not exist, and the
/// caller of the system call refuses a call with an invalid identifier.
pub fn get(id: u64) ?*Channel {
    if (id >= count) return null;
    return &channels[@intCast(id)];
}

/// Prepares the channels of the kernel.
pub fn init() void {
    for (&channels, 0..) |*channel, index| {
        channel.* = .{ .id = @intCast(index) };
    }
}

/// Expires the waits of every channel whose deadline has passed.
///
/// The function is called by the timer, before the scheduler chooses the
/// next task, and it returns the number of waits that expired.
pub fn expireAll(now: u64, result: u64) u32 {
    var expired_waits: u32 = 0;

    for (&channels) |*channel| {
        for (0..channel.queues.len) |side| {
            expired_waits += channel.expire(@intCast(side), now, result);
        }
    }

    return expired_waits;
}

/// The number of waits of a channel that expired.
pub fn expirations(id: u64, side: u64) u64 {
    const channel = get(id) orelse return 0;
    return channel.expirations(side);
}

fn wakeForTest(task: *anyopaque) void {
    const wakes: *u32 = @ptrCast(@alignCast(task));
    wakes.* += 1;
}

test "a wait without a deadline does not expire" {
    var queue: Queue = .{};
    var kind: u64 = 0;
    var value: u64 = 7;
    var wakes: u32 = 0;

    const waiter = Waiter{
        .kind = &kind,
        .value = &value,
        .task = &wakes,
        .wake = wakeForTest,
    };

    try std.testing.expect(queue.wait(waiter));
    try std.testing.expectEqual(@as(u32, 0), queue.expire(std.math.maxInt(u64), 1));
    try std.testing.expectEqual(@as(u32, 0), wakes);
    try std.testing.expectEqual(@as(u64, 0), kind);
    try std.testing.expectEqual(@as(u64, 7), value);
}

test "a wait expires when the deadline arrives" {
    var queue: Queue = .{};
    var kind: u64 = 0;
    var value: u64 = 7;
    var wakes: u32 = 0;

    const timeout_result: u64 = 0xFFFF_FFFF_FFFF_FFF3;
    const waiter = Waiter{
        .kind = &kind,
        .value = &value,
        .task = &wakes,
        .wake = wakeForTest,
        .deadline = 10,
    };

    try std.testing.expect(queue.wait(waiter));

    // Before the deadline the wait is kept.
    try std.testing.expectEqual(@as(u32, 0), queue.expire(9, timeout_result));
    try std.testing.expectEqual(@as(u32, 0), wakes);

    // The deadline is inclusive: the tick that reaches it expires the wait.
    try std.testing.expectEqual(@as(u32, 1), queue.expire(10, timeout_result));
    try std.testing.expectEqual(@as(u32, 1), wakes);
    try std.testing.expectEqual(timeout_result, kind);
    try std.testing.expectEqual(@as(u64, 0), value);
    try std.testing.expectEqual(@as(u64, 1), queue.expirations());

    // The wait was removed, and a second expiry does not wake the task
    // again.
    try std.testing.expectEqual(@as(u32, 0), queue.expire(11, timeout_result));
    try std.testing.expectEqual(@as(u32, 1), wakes);
}

test "the expiry takes only the waits that are due" {
    var queue: Queue = .{};
    var first_kind: u64 = 0;
    var second_kind: u64 = 0;
    var first_value: u64 = 1;
    var second_value: u64 = 2;
    var first_wakes: u32 = 0;
    var second_wakes: u32 = 0;

    try std.testing.expect(queue.wait(.{
        .kind = &first_kind,
        .value = &first_value,
        .task = &first_wakes,
        .wake = wakeForTest,
        .deadline = 5,
    }));
    try std.testing.expect(queue.wait(.{
        .kind = &second_kind,
        .value = &second_value,
        .task = &second_wakes,
        .wake = wakeForTest,
        .deadline = 10,
    }));

    try std.testing.expectEqual(@as(u32, 1), queue.expire(5, 0xA));
    try std.testing.expectEqual(@as(u32, 1), first_wakes);
    try std.testing.expectEqual(@as(u32, 0), second_wakes);
    try std.testing.expectEqual(@as(u64, 0xA), first_kind);
    try std.testing.expectEqual(@as(u64, 0), second_kind);

    try std.testing.expectEqual(@as(u32, 1), queue.expire(10, 0xB));
    try std.testing.expectEqual(@as(u32, 1), second_wakes);
    try std.testing.expectEqual(@as(u64, 0xB), second_kind);
}

test "a wait that was delivered does not expire" {
    var queue: Queue = .{};
    var kind: u64 = 0;
    var value: u64 = 7;
    var wakes: u32 = 0;

    const waiter = Waiter{
        .kind = &kind,
        .value = &value,
        .task = &wakes,
        .wake = wakeForTest,
        .deadline = 10,
    };

    try std.testing.expect(queue.wait(waiter));
    try std.testing.expect(queue.deliver(.{ .kind = 3, .value = 9 }));
    try std.testing.expectEqual(@as(u64, 3), kind);
    try std.testing.expectEqual(@as(u64, 9), value);
    try std.testing.expectEqual(@as(u32, 1), wakes);

    try std.testing.expectEqual(@as(u32, 0), queue.expire(10, 0xF));
    try std.testing.expectEqual(@as(u32, 1), wakes);
    try std.testing.expectEqual(@as(u64, 3), kind);
    try std.testing.expectEqual(@as(u64, 9), value);
}
