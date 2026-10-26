//************************************************************************//
//  keyboard.zig                                                          //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! F6.6: eventos de teclado PS/2 scancode set 1 (interface independente do IRQ).
//! O produtor deve ser serializado pelo controlador de interrupções; o consumidor
//! deve impedir interrupções concorrentes ao acessar a fila. Sem heap nem MMIO.

const std = @import("std");

pub const KeyEvent = struct {
    /// Código make do set 1 (sem o bit de release).
    scancode: u8,
    extended: bool,
    pressed: bool,
};

pub const EventQueue = struct {
    pub const capacity: usize = 64;
    events: [capacity]KeyEvent = undefined,
    head: usize = 0,
    len: usize = 0,
    dropped: usize = 0,

    /// Quando cheia, descarta o evento mais antigo para preservar o mais novo.
    /// Isso evita que um evento de liberação seja perdido enquanto uma tecla
    /// pressa permanece em estado inconsistente.
    pub fn push(self: *EventQueue, event: KeyEvent) bool {
        if (self.len == capacity) {
            _ = self.pop(); // descarta o mais antigo
            self.dropped +|= 1;
        }
        self.events[(self.head + self.len) % capacity] = event;
        self.len += 1;
        return true;
    }

    pub fn pop(self: *EventQueue) ?KeyEvent {
        if (self.len == 0) return null;
        const event = self.events[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return event;
    }
};

/// Decodificador mínimo de set 1: E0 indica uma tecla estendida.
/// E1 (Pause/Break) é descartado por completo para não gerar eventos falsos.
/// Respostas do controlador não são interpretadas como teclas.
pub const Set1Decoder = struct {
    extended: bool = false,
    pause_remaining: u8 = 0,

    pub fn feed(self: *Set1Decoder, byte: u8) ?KeyEvent {
        if (self.pause_remaining != 0) {
            self.pause_remaining -= 1;
            return null;
        }
        if (byte == 0xe1) {
            self.extended = false;
            self.pause_remaining = 5;
            return null;
        }
        if (byte == 0xe0) {
            self.extended = true;
            return null;
        }
        const extended = self.extended;
        self.extended = false;
        const code = byte & 0x7f;
        // 0x00/0x7f são inválidos; códigos acima de 0x58 não pertencem
        // ao subconjunto de teclas suportado neste marco.
        if (code == 0 or code > 0x58) return null;
        return .{ .scancode = code, .extended = extended, .pressed = byte & 0x80 == 0 };
    }
};

/// Alimenta a fila com um byte de scancode, sem alocar memória.
pub fn ingest(decoder: *Set1Decoder, queue: *EventQueue, byte: u8) void {
    if (decoder.feed(byte)) |event| _ = queue.push(event);
}

test "queue preserves FIFO order across wraparound" {
    var queue: EventQueue = .{};
    for (0..EventQueue.capacity) |i| {
        try std.testing.expect(queue.push(.{ .scancode = @intCast(i + 1), .extended = false, .pressed = true }));
    }
    for (0..32) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), queue.pop().?.scancode);
    }
    for (0..32) |i| {
        try std.testing.expect(queue.push(.{ .scancode = @intCast(i + 1), .extended = true, .pressed = false }));
    }
    for (32..EventQueue.capacity) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), queue.pop().?.scancode);
    }
    for (0..32) |i| {
        const event = queue.pop().?;
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), event.scancode);
        try std.testing.expect(event.extended);
        try std.testing.expect(!event.pressed);
    }
    try std.testing.expect(queue.pop() == null);
}

test "queue overflow drops newest event and records loss" {
    var queue: EventQueue = .{};
    for (0..EventQueue.capacity) |_| {
        try std.testing.expect(queue.push(.{ .scancode = 0x1e, .extended = false, .pressed = true }));
    }
    try std.testing.expect(queue.push(.{ .scancode = 0x30, .extended = false, .pressed = true }));
    try std.testing.expectEqual(@as(usize, 1), queue.dropped);
    try std.testing.expectEqual(@as(u8, 0x1e), queue.pop().?.scancode);
    try std.testing.expect(queue.push(.{ .scancode = 0x30, .extended = false, .pressed = true }));
}

test "set 1 decodes make break and extended keys" {
    var decoder: Set1Decoder = .{};
    var queue: EventQueue = .{};
    for ([_]u8{ 0x1e, 0x9e, 0xe0, 0x4d, 0xe0, 0xcd }) |byte| ingest(&decoder, &queue, byte);
    try std.testing.expectEqual(@as(usize, 4), queue.len);
    const press = queue.pop().?;
    try std.testing.expectEqual(@as(u8, 0x1e), press.scancode);
    try std.testing.expect(press.pressed);
    try std.testing.expect(!press.extended);
    try std.testing.expect(!queue.pop().?.pressed);
    const arrow = queue.pop().?;
    try std.testing.expectEqual(@as(u8, 0x4d), arrow.scancode);
    try std.testing.expect(arrow.extended);
    try std.testing.expect(arrow.pressed);
    const release = queue.pop().?;
    try std.testing.expect(release.extended);
    try std.testing.expect(!release.pressed);
}

test "pause sequence and invalid bytes do not create phantom events" {
    var decoder: Set1Decoder = .{};
    var queue: EventQueue = .{};
    for ([_]u8{ 0xe1, 0x1d, 0x45, 0xe1, 0x9d, 0xc5, 0x00, 0xff, 0xfa, 0xfe }) |byte| ingest(&decoder, &queue, byte);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
    ingest(&decoder, &queue, 0x20);
    try std.testing.expectEqual(@as(u8, 0x20), queue.pop().?.scancode);
}
