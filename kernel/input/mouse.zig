//************************************************************************//
//  mouse.zig                                                             //
//************************************************************************//
//                        This file is part of:                           //
//                              VorynOS                                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 VorynOS - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! F6.32: decodificador de pacotes do mouse PS/2 (protocolo de três bytes).
//!
//! Módulo **puro**: não lê portas, não faz syscalls e não aloca. O byte chega
//! do IRQ12 (ou de um teste, no host) e sai um pacote — ou nada, quando o
//! pacote ainda está incompleto ou o fluxo perdeu o sincronismo.
//!
//! Protocolo, para quem for ler o código sem a especificação ao lado: o
//! controlador 8042 entrega três bytes por movimento.
//!
//! ```text
//! byte 0: bit0 botão esquerdo, bit1 direito, bit2 meio
//!         bit3 SEMPRE 1 (é o sincronismo do pacote)
//!         bit4 sinal de X, bit5 sinal de Y
//!         bit6 overflow de X, bit7 overflow de Y
//! byte 1: movimento de X (magnitude; o sinal vem do byte 0)
//! byte 2: movimento de Y (idem)
//! ```
//!
//! Duas decisões que não são óbvias:
//!
//!   * **orientação**: no fio, Y positivo é *para cima*. O resto do kernel
//!     (raster, janelas, cursor) usa Y crescente *para baixo*, como o
//!     framebuffer. A inversão acontece aqui, uma vez, e o chamador recebe
//!     `dy` na orientação da tela;
//!   * **overflow** não é movimento válido: quando o bit 6 ou o bit 7 vem
//!     ligado, a magnitude de 8 bits não representa o deslocamento real. O
//!     valor é saturado em `max_motion` e o evento é contado em `overflows`,
//!     em vez de inventar um número que pareça exato.

const std = @import("std");

/// Maior deslocamento que um pacote pode representar em cada eixo.
pub const max_motion: i16 = 255;

/// Capacidade da fila entre o IRQ12 e o consumidor.
pub const queue_capacity: usize = 32;

/// O bit de sincronismo do primeiro byte.
const sync_bit: u8 = 0x08;
const left_button: u8 = 0x01;
const right_button: u8 = 0x02;
const middle_button: u8 = 0x04;
const x_sign: u8 = 0x10;
const y_sign: u8 = 0x20;
const x_overflow: u8 = 0x40;
const y_overflow: u8 = 0x80;

/// Um movimento decodificado, na orientação da tela.
pub const Packet = struct {
    /// Deslocamento horizontal: positivo para a direita.
    dx: i16,
    /// Deslocamento vertical: positivo para **baixo** (Y da tela).
    dy: i16,
    left: bool,
    right: bool,
    middle: bool,
};

pub const Decoder = struct {
    bytes: [3]u8 = .{ 0, 0, 0 },
    count: usize = 0,
    /// Pacotes completos entregues.
    packets: usize = 0,
    /// Primeiros bytes recusados por falta do bit de sincronismo.
    resyncs: usize = 0,
    /// Pacotes cujo deslocamento veio saturado.
    overflows: usize = 0,

    pub fn reset(self: *Decoder) void {
        self.* = .{};
    }

    /// Consome um byte. Devolve o pacote quando o terceiro byte fecha o
    /// pacote, e `null` enquanto ele está incompleto ou quando o byte é
    /// descartado.
    pub fn feed(self: *Decoder, byte: u8) ?Packet {
        if (self.count == 0) {
            // O bit 3 é sempre 1 em um primeiro byte válido. Sem ele o fluxo
            // perdeu o sincronismo (o 8042 pode entregar um byte de uma
            // transação anterior): descartar é a única opção segura, porque
            // aceitar o byte deslocaria todos os seguintes.
            if (byte & sync_bit == 0) {
                self.resyncs +|= 1;
                return null;
            }
        }
        self.bytes[self.count] = byte;
        self.count += 1;
        if (self.count < 3) return null;
        self.count = 0;

        const flags = self.bytes[0];
        var dx: i16 = @intCast(self.bytes[1]);
        var dy: i16 = @intCast(self.bytes[2]);
        if (flags & x_sign != 0) dx -= 256;
        if (flags & y_sign != 0) dy -= 256;

        if (flags & (x_overflow | y_overflow) != 0) {
            self.overflows +|= 1;
            if (flags & x_overflow != 0) dx = if (dx < 0) -max_motion else max_motion;
            if (flags & y_overflow != 0) dy = if (dy < 0) -max_motion else max_motion;
        }

        self.packets +|= 1;
        return .{
            .dx = dx,
            // O fio usa Y para cima; a tela usa Y para baixo.
            .dy = -dy,
            .left = flags & left_button != 0,
            .right = flags & right_button != 0,
            .middle = flags & middle_button != 0,
        };
    }
};

/// Fila fixa entre o IRQ12 e o consumidor.
///
/// Um produtor (a interrupção) e um consumidor (o kernel), com IRQs locais
/// desabilitadas na retirada. Cheia, a fila **descarta o pacote mais novo** e
/// conta a perda: sobrescrever o mais antigo reordenaria o movimento, e um
/// movimento fora de ordem é pior que um movimento perdido.
pub const Queue = struct {
    items: [queue_capacity]Packet = undefined,
    head: usize = 0,
    count: usize = 0,
    dropped: usize = 0,

    pub fn push(self: *Queue, packet: Packet) bool {
        if (self.count == queue_capacity) {
            self.dropped +|= 1;
            return false;
        }
        const index = (self.head + self.count) % queue_capacity;
        self.items[index] = packet;
        self.count += 1;
        return true;
    }

    pub fn pop(self: *Queue) ?Packet {
        if (self.count == 0) return null;
        const packet = self.items[self.head];
        self.head = (self.head + 1) % queue_capacity;
        self.count -= 1;
        return packet;
    }

    pub fn full(self: *const Queue) bool {
        return self.count == queue_capacity;
    }
};

test "a complete packet reports motion and the button state" {
    var decoder = Decoder{};
    // 0x09: sincronismo + botão esquerdo.
    try std.testing.expect(decoder.feed(0x09) == null);
    try std.testing.expect(decoder.feed(0x05) == null);
    const packet = decoder.feed(0x03).?;
    try std.testing.expectEqual(@as(i16, 5), packet.dx);
    // O fio mandou +3 (para cima); a tela recebe -3 (para cima também).
    try std.testing.expectEqual(@as(i16, -3), packet.dy);
    try std.testing.expect(packet.left);
    try std.testing.expect(!packet.right);
    try std.testing.expect(!packet.middle);
    try std.testing.expectEqual(@as(usize, 1), decoder.packets);
}

test "the sign bits flip both axes and the vertical axis is inverted" {
    var decoder = Decoder{};
    _ = decoder.feed(0x08 | x_sign | y_sign);
    _ = decoder.feed(0x01); // -255 em X
    const packet = decoder.feed(0xFF).?; // -1 no fio, ou seja, para baixo
    try std.testing.expectEqual(@as(i16, -255), packet.dx);
    try std.testing.expectEqual(@as(i16, 1), packet.dy);

    // Sem o bit de sinal, o fio mandou +10 (para cima): a tela recebe -10.
    var second = Decoder{};
    _ = second.feed(0x08);
    _ = second.feed(0x00);
    const up = second.feed(0x0A).?;
    try std.testing.expectEqual(@as(i16, 0), up.dx);
    try std.testing.expectEqual(@as(i16, -10), up.dy);
}

test "a byte without the synchronism bit is discarded and counted" {
    var decoder = Decoder{};
    // 0x00 não é um primeiro byte válido: sem o bit 3, o pacote é lixo.
    try std.testing.expect(decoder.feed(0x00) == null);
    try std.testing.expectEqual(@as(usize, 1), decoder.resyncs);
    try std.testing.expectEqual(@as(usize, 0), decoder.count);

    // Em seguida um pacote válido é aceito normalmente.
    _ = decoder.feed(0x08);
    _ = decoder.feed(0x02);
    const packet = decoder.feed(0x00).?;
    try std.testing.expectEqual(@as(i16, 2), packet.dx);
    try std.testing.expectEqual(@as(i16, 0), packet.dy);
    try std.testing.expectEqual(@as(usize, 1), decoder.resyncs);
}

test "overflow saturates the axis and is counted instead of guessed" {
    var decoder = Decoder{};
    _ = decoder.feed(0x08 | x_overflow | y_overflow | x_sign);
    _ = decoder.feed(0x10);
    const packet = decoder.feed(0x10).?;
    try std.testing.expectEqual(-max_motion, packet.dx);
    try std.testing.expectEqual(-max_motion, packet.dy);
    try std.testing.expectEqual(@as(usize, 1), decoder.overflows);
}

test "each button bit is reported independently" {
    const cases = [_]struct { flags: u8, left: bool, right: bool, middle: bool }{
        .{ .flags = 0x08, .left = false, .right = false, .middle = false },
        .{ .flags = 0x09, .left = true, .right = false, .middle = false },
        .{ .flags = 0x0A, .left = false, .right = true, .middle = false },
        .{ .flags = 0x0C, .left = false, .right = false, .middle = true },
        .{ .flags = 0x0F, .left = true, .right = true, .middle = true },
    };
    for (cases) |case| {
        var decoder = Decoder{};
        _ = decoder.feed(case.flags);
        _ = decoder.feed(0);
        const packet = decoder.feed(0).?;
        try std.testing.expectEqual(case.left, packet.left);
        try std.testing.expectEqual(case.right, packet.right);
        try std.testing.expectEqual(case.middle, packet.middle);
    }
}

test "the queue is FIFO, keeps order and drops the newest when full" {
    var queue = Queue{};
    try std.testing.expect(queue.pop() == null);
    for (0..queue_capacity) |index| {
        try std.testing.expect(queue.push(.{
            .dx = @intCast(index),
            .dy = 0,
            .left = false,
            .right = false,
            .middle = false,
        }));
    }
    try std.testing.expect(queue.full());
    try std.testing.expect(!queue.push(.{ .dx = 99, .dy = 0, .left = false, .right = false, .middle = false }));
    try std.testing.expectEqual(@as(usize, 1), queue.dropped);

    // A ordem é preservada, e o pacote descartado é o mais novo.
    for (0..queue_capacity) |index| {
        const packet = queue.pop().?;
        try std.testing.expectEqual(@as(i16, @intCast(index)), packet.dx);
    }
    try std.testing.expect(queue.pop() == null);
    try std.testing.expect(!queue.full());
}

test "reset forgets a partial packet but keeps nothing else" {
    var decoder = Decoder{};
    _ = decoder.feed(0x08);
    _ = decoder.feed(0x01);
    try std.testing.expectEqual(@as(usize, 2), decoder.count);
    decoder.reset();
    try std.testing.expectEqual(@as(usize, 0), decoder.count);
    try std.testing.expectEqual(@as(usize, 0), decoder.packets);
}
