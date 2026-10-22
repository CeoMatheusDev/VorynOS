//************************************************************************//
//  channel.zig                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
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
//! The channel does not block. A task that asks for a message and finds
//! the queue empty receives the error of the empty queue, and the task
//! that waits for a message has to ask again. The blocking is a separate
//! increment, because it requires the system call to be able to resume
//! after the message arrives.

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
        // The moment of the message is read from the counter of the
        // processor, and it is what makes the latency of the delivery a
        // measurement instead of a constant.
        self.sent_at = context.timestamp();
        return true;
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
