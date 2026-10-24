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

/// Uma janela opaca, em pixels da superfície de destino.
pub const Window = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color: u32,
};

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
        var hash: u64 = 0xcbf29ce484222325;
        var row: u32 = 0;
        while (row < self.height) : (row += 1) {
            const start: usize = @intCast(@as(u64, row) * self.stride);
            for (self.pixels[start .. start + self.width]) |pixel| {
                hash ^= @as(u8, @truncate(pixel));
                hash *%= 0x100000001b3;
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
