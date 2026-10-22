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

/// A task that waits for a message of a queue.
///
/// The waiter carries the address of the two words where the result of the
/// call is written, e o endereço da tarefa que espera. A entrega escreve o
/// resultado **direto** no contexto salvo da tarefa, e por isso o
/// chamador do canal não precisa saber nada sobre o escalonador.
pub const Waiter = struct {
    /// The address where the type of the message is written.
    kind: *u64,
    /// The address where the value of the message is written.
    value: *u64,
    /// The task that waits, given back to the routine that wakes it.
    task: *anyopaque,
    /// The routine that makes the task ready again.
    wake: *const fn (task: *anyopaque) void,
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
    /// O valor é o que permite medir a latência da entrega de verdade: o
    /// intervalo entre a mensagem sair e a mensagem chegar.
    delivered_at: u64 = 0,

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
    /// A task que espera é acordada pela mensagem que chega, e a mensagem
    /// não fica na fila: ela é entregue direto ao contexto da tarefa.
    ///
    /// A função devolve falso quando a fila já tem o número máximo de
    /// tarefas esperando.
    pub fn wait(self: *Queue, waiter: Waiter) bool {
        for (&self.waiters) |*entry| {
            if (entry.* != null) continue;
            entry.* = waiter;
            return true;
        }
        return false;
    }

    /// Removes a wait of a task, sem entregar mensagem alguma.
    ///
    /// A função devolve verdadeiro quando a espera existia.
    pub fn cancelWait(self: *Queue, waiter: Waiter) bool {
        for (&self.waiters) |*entry| {
            const value = entry.* orelse continue;
            if (value.task != waiter.task) continue;
            entry.* = null;
            return true;
        }
        return false;
    }

    /// Entrega uma mensagem a uma tarefa que espera, se houver uma.
    ///
    /// A função devolve verdadeiro quando a mensagem foi entregue, e falso
    /// quando não havia nenhuma tarefa esperando, e a mensagem tem de ir
    /// para a fila.
    pub fn deliver(self: *Queue, message: Message) bool {
        for (&self.waiters) |*entry| {
            const waiter = entry.* orelse continue;

            // O resultado da chamada é escrito direto no contexto salvo da
            // tarefa, e a tarefa continua depois da chamada, como se a
            // chamada tivesse respondido.
            waiter.kind.* = message.kind;
            waiter.value.* = message.value;
            entry.* = null;

            // A tarefa acordada é escolhida pelo escalonador, e a entrega
            // registra o momento em que a mensagem chegou.
            self.delivered += 1;
            self.delivered_at = context.timestamp();
            waiter.wake(waiter.task);
            return true;
        }
        return false;
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

    /// Registra uma tarefa que espera por uma mensagem de um lado.
    ///
    /// A função devolve falso quando o lado não existe, ou quando a fila
    /// dele já tem o número máximo de tarefas esperando.
    pub fn wait(self: *Channel, side: u64, waiter: Waiter) bool {
        if (side >= self.queues.len) return false;
        return self.queues[side].wait(waiter);
    }

    /// Remove a espera de uma tarefa em um lado.
    pub fn cancelWait(self: *Channel, side: u64, waiter: Waiter) bool {
        if (side >= self.queues.len) return false;
        return self.queues[side].cancelWait(waiter);
    }

    /// Entrega uma mensagem a uma tarefa que espera em um lado.
    ///
    /// A função devolve verdadeiro quando a mensagem foi entregue, e a
    /// mensagem não fica na fila.
    pub fn deliver(self: *Channel, side: u64, message: Message) bool {
        if (side >= self.queues.len) return false;
        return self.queues[side].deliver(message);
    }

    /// Entrega uma mensagem a uma tarefa que espera, ou a põe na fila.
    ///
    /// A função é o caminho único de uma mensagem que sai, e por isso é
    /// ela que marca o momento da saída: a latência da entrega é o
    /// intervalo entre esse momento e o momento em que a mensagem chegou à
    /// tarefa que esperava.
    pub fn post(self: *Channel, side: u64, message: Message) bool {
        if (side >= self.queues.len) return false;

        const queue = &self.queues[side];
        queue.sent_at = context.timestamp();

        if (queue.deliver(message)) return true;
        return queue.send(message);
    }

    /// O número de mensagens que chegaram a uma tarefa que esperava.
    pub fn deliveries(self: *Channel, side: u64) u64 {
        if (side >= self.queues.len) return 0;
        return self.queues[side].delivered;
    }

    /// O número de ciclos entre a mensagem sair e a mensagem chegar.
    ///
    /// A latência medida é a da entrega: o intervalo entre o momento em
    /// que a mensagem foi posta na fila e o momento em que ela chegou à
    /// tarefa que esperava.
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
