//************************************************************************//
//  composition.zig                                                       //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Composição de janelas opacas em uma superfície do modo usuário.
//!
//! O módulo é puro: não chama syscalls, não acessa hardware e não aloca
//! memória. O compositor de usuário mantém a superfície, a lista de janelas
//! e a ordem z; o kernel recebe apenas o retângulo validado de `present`.
//! A última janela da lista fica na frente.
//!
//! O F6.28 usa este módulo na aplicação nativa para compor um quadro de
//! 32x24 pixels. O quadro é apresentado como uma cópia validada, sem expor
//! o framebuffer ao processo. O compartilhamento de superfícies entre
//! clientes e compositor exige uma capability de memória e continua fora
//! do contrato atual.

const std = @import("std");

const fnv_offset_basis: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

/// Uma janela opaca, em pixels da superfície de destino.
pub const Window = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color: u32,
};

/// Fixed-capacity z-ordered window registry. No heap allocation or syscalls.
/// The last registered window is the topmost; IDs are stable across raises.
pub fn WindowStack(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Error = error{ Full, Duplicate, NotFound, Unauthorized };
        const Entry = struct { id: u64, owner: u64, window: Window };
        entries: [capacity]Entry = undefined,
        len: usize = 0,

        pub fn add(self: *Self, id: u64, window: Window) Error!void {
            if (self.indexOf(id) != null) return error.Duplicate;
            if (self.len == capacity) return error.Full;
            self.entries[self.len] = .{ .id = id, .owner = 0, .window = window };
            self.len += 1;
        }

        pub fn addOwned(self: *Self, owner: u64, id: u64, window: Window) Error!void {
            try self.add(id, window);
            self.entries[self.len - 1].owner = owner;
        }

        pub fn moveOwned(self: *Self, owner: u64, id: u64, x: u32, y: u32) Error!void {
            const index = self.indexOf(id) orelse return error.NotFound;
            if (self.entries[index].owner != owner) return error.Unauthorized;
            try self.move(id, x, y);
        }

        pub fn removeOwned(self: *Self, owner: u64, id: u64) Error!void {
            const index = self.indexOf(id) orelse return error.NotFound;
            if (self.entries[index].owner != owner) return error.Unauthorized;
            try self.remove(id);
        }

        pub fn raiseOwned(self: *Self, owner: u64, id: u64) Error!void {
            const index = self.indexOf(id) orelse return error.NotFound;
            if (self.entries[index].owner != owner) return error.Unauthorized;
            try self.raise(id);
        }

        pub fn remove(self: *Self, id: u64) Error!void {
            const index = self.indexOf(id) orelse return error.NotFound;
            var i = index;
            while (i + 1 < self.len) : (i += 1) self.entries[i] = self.entries[i + 1];
            self.len -= 1;
        }

        pub fn raise(self: *Self, id: u64) Error!void {
            const index = self.indexOf(id) orelse return error.NotFound;
            const selected = self.entries[index];
            var i = index;
            while (i + 1 < self.len) : (i += 1) self.entries[i] = self.entries[i + 1];
            self.entries[self.len - 1] = selected;
        }

        pub fn move(self: *Self, id: u64, x: u32, y: u32) Error!void {
            const index = self.indexOf(id) orelse return error.NotFound;
            self.entries[index].window.x = x;
            self.entries[index].window.y = y;
        }

        pub fn compose(self: *const Self, surface: *Surface, background: u32) void {
            surface.fillBackground(background);
            for (self.entries[0..self.len]) |entry| surface.paint(entry.window);
        }

        fn indexOf(self: *const Self, id: u64) ?usize {
            for (self.entries[0..self.len], 0..) |entry, index| {
                if (entry.id == id) return index;
            }
            return null;
        }
    };
}

test "window stack maintains z order and stable IDs" {
    var pixels: [4]u32 = @splat(0);
    var surface = try Surface.init(&pixels, 2, 2, 2);
    var stack: WindowStack(2) = .{};
    const back: Window = .{ .x = 0, .y = 0, .width = 2, .height = 2, .color = 0x11 };
    const front: Window = .{ .x = 0, .y = 0, .width = 1, .height = 1, .color = 0x22 };
    try stack.add(100, back);
    try stack.add(200, front);
    try std.testing.expectError(error.Duplicate, stack.add(100, front));
    try std.testing.expectError(error.Full, stack.add(300, front));
    stack.compose(&surface, 0);
    try std.testing.expectEqual(@as(u32, 0x22), pixels[0]);
    try stack.raise(100);
    stack.compose(&surface, 0);
    try std.testing.expectEqual(@as(u32, 0x11), pixels[0]);
    try stack.move(100, 1, 1);
    stack.compose(&surface, 0);
    try std.testing.expectEqual(@as(u32, 0x22), pixels[0]);
    try stack.remove(200);
    stack.compose(&surface, 0);
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
    try std.testing.expectError(error.NotFound, stack.remove(200));
    try std.testing.expectError(error.NotFound, stack.raise(200));
}

/// Superfície linear de pixels de 32 bits.
///
/// `stride` é o número de pixels entre o início de duas linhas. Ele pode
/// ser maior que `width`; a composição nunca escreve no preenchimento entre
/// as linhas.
pub const Surface = struct {
    width: u32,
    height: u32,
    stride: u32,
    pixels: []u32,

    /// Valida a geometria e o tamanho do buffer antes de qualquer escrita.
    pub fn init(pixels: []u32, width: u32, height: u32, stride: u32) error{InvalidGeometry}!Surface {
        if (width == 0 or height == 0 or stride < width) {
            return error.InvalidGeometry;
        }

        const required = std.math.mul(u64, stride, height) catch {
            return error.InvalidGeometry;
        };
        if (required > @as(u64, @intCast(pixels.len))) {
            return error.InvalidGeometry;
        }

        return .{
            .width = width,
            .height = height,
            .stride = stride,
            .pixels = pixels,
        };
    }

    /// Preenche o fundo e desenha as janelas na ordem da lista.
    pub fn compose(self: *Surface, background: u32, windows: []const Window) void {
        self.fillBackground(background);
        for (windows) |window| {
            self.paint(window);
        }
    }

    fn fillBackground(self: *Surface, color: u32) void {
        var row: u32 = 0;
        while (row < self.height) : (row += 1) {
            const start: usize = @intCast(@as(u64, row) * self.stride);
            @memset(self.pixels[start .. start + self.width], color);
        }
    }

    fn paint(self: *Surface, window: Window) void {
        // A soma em 64 bits impede que uma coordenada extrema dê a volta e
        // faça a janela aparecer no lado oposto da superfície.
        const left: u64 = @min(@as(u64, window.x), self.width);
        const top: u64 = @min(@as(u64, window.y), self.height);
        const right: u64 = @min(@as(u64, window.x) + window.width, self.width);
        const bottom: u64 = @min(@as(u64, window.y) + window.height, self.height);
        if (right <= left or bottom <= top) return;

        const row_bytes: usize = @intCast(right - left);
        var row: u64 = top;
        while (row < bottom) : (row += 1) {
            const start: usize = @intCast(row * self.stride + left);
            @memset(self.pixels[start .. start + row_bytes], window.color);
        }
    }

    /// Hash determinístico dos pixels visíveis, na ordem das linhas.
    ///
    /// O F6.28 usa o hash para comparar o quadro composto pelo processo com
    /// o screenshot P6 capturado pelo QEMU. Como o quadro usa apenas tons de
    /// cinza, o mesmo valor aparece nos três canais do PPM e a comparação
    /// não depende da ordem RGB/BGR do framebuffer.
    pub fn checksum(self: *const Surface) u64 {
        var hash: u64 = fnv_offset_basis;
        var row: u32 = 0;
        while (row < self.height) : (row += 1) {
            const start: usize = @intCast(@as(u64, row) * self.stride);
            for (self.pixels[start .. start + self.width]) |pixel| {
                hash ^= @as(u8, @truncate(pixel));
                hash *%= fnv_prime;
            }
        }
        return hash;
    }

    /// Hash determinístico de um retângulo visível da superfície.
    ///
    /// O F6.29 usa a função para comparar a janela que o cliente copiou com
    /// o checksum que o cliente publicou. A região tem de estar inteiramente
    /// dentro da superfície; uma geometria inválida não é recortada, porque
    /// um checksum de uma região diferente da anunciada não prova nada.
    pub fn checksumRegion(self: *const Surface, x: u32, y: u32, width: u32, height: u32) ?u64 {
        if (width == 0 or height == 0) return null;

        const right: u64 = @as(u64, x) + width;
        const bottom: u64 = @as(u64, y) + height;
        if (right > self.width or bottom > self.height) return null;

        var hash: u64 = fnv_offset_basis;
        var row: u64 = y;
        while (row < bottom) : (row += 1) {
            const start: usize = @intCast(row * self.stride + x);
            const end: usize = start + @as(usize, width);
            for (self.pixels[start..end]) |pixel| {
                hash ^= @as(u8, @truncate(pixel));
                hash *%= fnv_prime;
            }
        }
        return hash;
    }
};

test "composition fills the background and respects the z order" {
    var pixels: [20]u32 = @splat(0xDEADBEEF);
    var surface = try Surface.init(&pixels, 4, 4, 5);
    const windows = [_]Window{
        .{ .x = 0, .y = 0, .width = 3, .height = 3, .color = 0x11111111 },
        .{ .x = 1, .y = 1, .width = 2, .height = 2, .color = 0x22222222 },
    };

    surface.compose(0x33333333, &windows);

    try std.testing.expectEqual(@as(u32, 0x11111111), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0x22222222), pixels[6]);
    try std.testing.expectEqual(@as(u32, 0x33333333), pixels[3]);
    // O preenchimento da linha não é tocado.
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), pixels[4]);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), pixels[19]);
}

test "composition clips extreme windows without wrapping" {
    var pixels: [12]u32 = @splat(0xAAAAAAAA);
    var surface = try Surface.init(&pixels, 3, 4, 3);
    const windows = [_]Window{
        .{ .x = std.math.maxInt(u32), .y = 0, .width = 1, .height = 1, .color = 0xFFFFFFFF },
        .{ .x = 1, .y = 2, .width = std.math.maxInt(u32), .height = std.math.maxInt(u32), .color = 0x55555555 },
    };

    surface.compose(0x01010101, &windows);

    try std.testing.expectEqual(@as(u32, 0x01010101), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0x01010101), pixels[6]);
    try std.testing.expectEqual(@as(u32, 0x55555555), pixels[7]);
    try std.testing.expectEqual(@as(u32, 0x55555555), pixels[11]);
}

test "composition checksum covers the visible pixels and ignores padding" {
    var pixels: [8]u32 = @splat(0);
    var surface = try Surface.init(&pixels, 2, 2, 4);
    surface.compose(0x00202020, &.{});
    const original = surface.checksum();

    // O preenchimento entre as linhas não entra no hash.
    pixels[2] = 0xFFFFFFFF;
    pixels[3] = 0xFFFFFFFF;
    try std.testing.expectEqual(original, surface.checksum());

    // Um pixel visível alterado muda o hash.
    pixels[0] = 0x00303030;
    try std.testing.expect(original != surface.checksum());
}

test "composition checksum uses the low byte of each pixel" {
    var pixels: [1]u32 = @splat(0);
    var surface = try Surface.init(&pixels, 1, 1, 1);
    surface.compose(0x00ABCDEF, &.{});
    // O checksum do contrato usa o byte baixo; o teste usa um valor que não
    // é cinza para deixar a regra explícita.
    var expected: u64 = 0xcbf29ce484222325;
    expected ^= 0xEF;
    expected *%= 0x100000001b3;
    try std.testing.expectEqual(expected, surface.checksum());
}

test "composition rejects invalid surfaces before writing" {
    var pixels: [4]u32 = @splat(0);
    try std.testing.expectError(error.InvalidGeometry, Surface.init(&pixels, 0, 1, 1));
    try std.testing.expectError(error.InvalidGeometry, Surface.init(&pixels, 2, 1, 1));
    try std.testing.expectError(error.InvalidGeometry, Surface.init(&pixels, 3, 2, 3));
    try std.testing.expectError(error.InvalidGeometry, Surface.init(&pixels, 1, 1, std.math.maxInt(u32)));
}

test "region checksum matches an independent hash and rejects clipping" {
    var pixels: [20]u32 = @splat(0);
    var surface = try Surface.init(&pixels, 4, 4, 5);
    surface.compose(0x00202020, &.{});
    pixels[6] = 0x00112233;
    pixels[7] = 0x00445566;
    pixels[11] = 0x00778899;
    pixels[12] = 0x00AABBCC;

    var expected: u64 = 0xcbf29ce484222325;
    for ([_]u8{ 0x33, 0x66, 0x99, 0xCC }) |byte| {
        expected ^= byte;
        expected *%= 0x100000001b3;
    }
    try std.testing.expectEqual(@as(?u64, expected), surface.checksumRegion(1, 1, 2, 2));

    try std.testing.expectEqual(@as(?u64, null), surface.checksumRegion(3, 0, 2, 1));
    try std.testing.expectEqual(@as(?u64, null), surface.checksumRegion(0, 3, 1, 2));
    try std.testing.expectEqual(@as(?u64, null), surface.checksumRegion(0, 0, 0, 1));
}
