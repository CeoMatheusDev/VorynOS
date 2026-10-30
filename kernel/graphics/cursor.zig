//************************************************************************//
//  cursor.zig                                                            //
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

//! F6.32: o cursor do ponteiro — uma seta desenhada pelo kernel.
//!
//! Modelo puro: não lê dispositivo, não aloca e não conhece processos. O
//! chamador dá a superfície e a posição; o módulo desenha, recorta e diz
//! qual retângulo precisa ser recomposto.
//!
//! **Por que não há "salvar e restaurar"**: guardar os pixels embaixo da
//! seta parece mais barato, mas o que foi salvo envelhece a cada janela
//! desenhada por cima. Restaurar um retângulo velho espalharia pixels de uma
//! cena que já não existe. A regra adotada é recompor o retângulo a partir do
//! **modelo** das janelas (o compositor) e desenhar a seta por último — mais
//! caro em pixels, e correto em qualquer ordem de eventos.
//!
//! A seta é definida como texto, para que quem ler o arquivo veja a forma:
//!
//! ```text
//! #...........
//! ##..........
//! #o#.........
//! #oo#........
//! #ooo#.......
//! #oooo#......
//! #ooooo#.....
//! #oooooo#....
//! #ooooo####..
//! #oo#oo#.....
//! #o#.#oo#....
//! ##..#oo#....
//! #....#oo#...
//! .....#oo#...
//! ......##....
//! ```
//!
//! `#` é o contorno (`outline`), `o` o preenchimento (`fill`) e `.` é
//! transparente — o pixel da cena por baixo continua intacto.

const std = @import("std");
const raster = @import("raster.zig");
const compositor = @import("compositor.zig");

pub const Arrow = struct {
    pub const width: usize = 12;
    pub const height: usize = 15;
    /// A ponta da seta é o pixel (0, 0): a posição do cursor é a ponta, e
    /// não o canto do retângulo que a contém.
    pub const hotspot_x: usize = 0;
    pub const hotspot_y: usize = 0;

    pub const rows: [height][]const u8 = .{
        "#...........",
        "##..........",
        "#o#.........",
        "#oo#........",
        "#ooo#.......",
        "#oooo#......",
        "#ooooo#.....",
        "#oooooo#....",
        "#ooooo####..",
        "#oo#oo#.....",
        "#o#.#oo#....",
        "##..#oo#....",
        "#....#oo#...",
        ".....#oo#...",
        "......##....",
    };
};

pub const Palette = struct {
    outline: [4]u8,
    fill: [4]u8,
};

/// A seta com posição. `x` e `y` são a ponta, em pixels da superfície.
pub const Cursor = struct {
    x: usize = 0,
    y: usize = 0,

    /// Limita a posição para que a seta inteira caiba na superfície.
    ///
    /// Um cursor parcialmente fora da tela é recusado de propósito: o kernel
    /// teria de recortar a cada desenho e a ponta poderia ficar invisível,
    /// com o ponteiro "preso" na borda sem nada para onde apontar.
    pub fn clamp(x: usize, y: usize, width: usize, height: usize) Cursor {
        const max_x = width -| Arrow.width;
        const max_y = height -| Arrow.height;
        return .{ .x = @min(x, max_x), .y = @min(y, max_y) };
    }

    /// Aplica um deslocamento relativo, saturando nos limites da superfície.
    pub fn moved(self: Cursor, dx: i32, dy: i32, width: usize, height: usize) Cursor {
        const next_x = @as(i64, @intCast(self.x)) + dx;
        const next_y = @as(i64, @intCast(self.y)) + dy;
        const clamped_x: usize = if (next_x < 0) 0 else @intCast(next_x);
        const clamped_y: usize = if (next_y < 0) 0 else @intCast(next_y);
        return clamp(clamped_x, clamped_y, width, height);
    }

    /// Retângulo que a seta ocupa, já recortado pela superfície.
    pub fn rect(self: Cursor, width: usize, height: usize) compositor.Rect {
        const visible_width = @min(Arrow.width, width -| self.x);
        const visible_height = @min(Arrow.height, height -| self.y);
        return .{ .x = @min(self.x, width), .y = @min(self.y, height), .width = visible_width, .height = visible_height };
    }

    /// Desenha a seta. Devolve quantos pixels foram escritos.
    pub fn paint(self: Cursor, surface: *raster.Surface, palette: Palette) usize {
        var written: usize = 0;
        for (Arrow.rows, 0..) |row, dy| {
            for (row, 0..) |character, dx| {
                const color: [4]u8 = switch (character) {
                    '#' => palette.outline,
                    'o' => palette.fill,
                    else => continue,
                };
                const x = self.x + dx;
                const y = self.y + dy;
                if (x >= surface.width or y >= surface.height) continue;
                surface.pixel(x, y, color);
                written += 1;
            }
        }
        return written;
    }
};

test "the sprite is rectangular and uses only the three legal characters" {
    try std.testing.expectEqual(Arrow.height, Arrow.rows.len);
    for (Arrow.rows) |row| {
        try std.testing.expectEqual(Arrow.width, row.len);
        for (row) |character| {
            try std.testing.expect(character == '#' or character == 'o' or character == '.');
        }
    }
    // A ponta é o primeiro pixel: uma seta cujo hotspot não está na ponta
    // aponta para o lado errado do que o usuário vê.
    try std.testing.expectEqual(@as(u8, '#'), Arrow.rows[0][0]);
    try std.testing.expectEqual(@as(usize, 0), Arrow.hotspot_x);
    try std.testing.expectEqual(@as(usize, 0), Arrow.hotspot_y);
}

test "paint writes the outline and the fill, and leaves transparent pixels alone" {
    const palette: Palette = .{ .outline = .{ 0, 0, 0, 0xff }, .fill = .{ 0xff, 0xff, 0xff, 0xff } };
    var pixels: [Arrow.width * Arrow.height * 4]u8 = @splat(0xaa);
    var surface = try raster.Surface.init(&pixels, Arrow.width, Arrow.height, Arrow.width * 4);
    const written = (Cursor{ .x = 0, .y = 0 }).paint(&surface, palette);

    var expected: usize = 0;
    for (Arrow.rows) |row| for (row) |character| {
        if (character != '.') expected += 1;
    };
    try std.testing.expectEqual(expected, written);

    // O primeiro pixel é contorno; o (1, 3) é preenchimento.
    try std.testing.expectEqualSlices(u8, &palette.outline, pixels[0..4]);
    const offset = (3 * Arrow.width + 1) * 4;
    try std.testing.expectEqualSlices(u8, &palette.fill, pixels[offset..][0..4]);
    // O canto inferior direito da seta é transparente: 0xaa sobreviveu.
    const transparent = (Arrow.height - 1) * Arrow.width * 4 + (Arrow.width - 1) * 4;
    try std.testing.expectEqual(@as(u8, 0xaa), pixels[transparent]);
}

test "paint clips at the right and bottom edges without going out of bounds" {
    const palette: Palette = .{ .outline = .{ 1, 1, 1, 1 }, .fill = .{ 2, 2, 2, 2 } };
    // Superfície menor que a seta: tudo é recortado, nada estoura.
    var pixels: [4 * 4 * 4]u8 = @splat(0xaa);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    const written = (Cursor{ .x = 0, .y = 0 }).paint(&surface, palette);
    try std.testing.expect(written > 0);
    try std.testing.expect(written < Arrow.width * Arrow.height);
    try std.testing.expectEqualSlices(u8, &palette.outline, pixels[0..4]);

    // Uma posição fora da superfície não escreve nada e não estoura.
    var wide: [Arrow.width * Arrow.height * 4]u8 = @splat(0);
    var fresh = try raster.Surface.init(&wide, Arrow.width, Arrow.height, Arrow.width * 4);
    try std.testing.expectEqual(@as(usize, 0), (Cursor{ .x = Arrow.width, .y = 0 }).paint(&fresh, palette));
}

test "clamp keeps the whole arrow inside and moved saturates at the edges" {
    const start = Cursor.clamp(100, 100, 20, 20);
    try std.testing.expectEqual(@as(usize, 20 - Arrow.width), start.x);
    try std.testing.expectEqual(@as(usize, 20 - Arrow.height), start.y);

    // Uma superfície menor que a seta não tem posição válida: a posição 0 e
    // o recorte de `paint` cuidam do resto.
    const tiny = Cursor.clamp(5, 5, 2, 2);
    try std.testing.expectEqual(@as(usize, 0), tiny.x);

    const middle = Cursor{ .x = 10, .y = 10 };
    try std.testing.expectEqual(@as(usize, 0), middle.moved(-100, -100, 64, 64).x);
    try std.testing.expectEqual(@as(usize, 0), middle.moved(-100, -100, 64, 64).y);
    const far = middle.moved(1000, 1000, 64, 64);
    try std.testing.expectEqual(@as(usize, 64 - Arrow.width), far.x);
    try std.testing.expectEqual(@as(usize, 64 - Arrow.height), far.y);
    // Um deslocamento pequeno é aplicado exatamente.
    const step = middle.moved(3, -4, 64, 64);
    try std.testing.expectEqual(@as(usize, 13), step.x);
    try std.testing.expectEqual(@as(usize, 6), step.y);
}

test "the rectangle is clipped and matches what paint would touch" {
    const cursor = Cursor{ .x = 6, .y = 4 };
    const rect = cursor.rect(10, 10);
    try std.testing.expectEqual(@as(usize, 6), rect.x);
    try std.testing.expectEqual(@as(usize, 4), rect.y);
    try std.testing.expectEqual(@as(usize, 10 - 6), rect.width);
    try std.testing.expectEqual(@as(usize, 10 - 4), rect.height);
}
