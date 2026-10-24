//************************************************************************//
//  raster.zig                                                            //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! F6: rasterização de retângulos em framebuffer linear 32 bpp.
//! Módulo puro: não acessa endereços físicos nem requer privilégios.
//! O chamador é responsável por mapear a memória de vídeo com segurança.

const std = @import("std");

pub const Error = error{ InvalidGeometry, BufferTooSmall, UnsupportedFormat };

pub const Surface = struct {
    pixels: []u8,
    width: usize,
    height: usize,
    pitch: usize,

    /// pitch em bytes; cada pixel ocupa 4 bytes (formato nativo GOP).
    pub fn init(pixels: []u8, width: usize, height: usize, pitch: usize) Error!Surface {
        if (width == 0 or height == 0) return error.InvalidGeometry;
        const row_bytes = std.math.mul(usize, width, 4) catch return error.InvalidGeometry;
        if (pitch < row_bytes) return error.InvalidGeometry;
        const required = std.math.mul(usize, pitch, height - 1) catch return error.InvalidGeometry;
        const total = std.math.add(usize, required, row_bytes) catch return error.InvalidGeometry;
        if (pixels.len < total) return error.BufferTooSmall;
        return .{ .pixels = pixels, .width = width, .height = height, .pitch = pitch };
    }

    /// Grava bytes do pixel na ordem fornecida pelo chamador.
    pub fn pixel(self: *Surface, x: usize, y: usize, color: [4]u8) void {
        if (x >= self.width or y >= self.height) return;
        const offset = y * self.pitch + x * 4;
        @memcpy(self.pixels[offset..][0..4], &color);
    }

    /// Retângulo com coordenadas e tamanho unsigned; clipping sem overflow.
    pub fn fillRect(self: *Surface, x: usize, y: usize, width: usize, height: usize, color: [4]u8) void {
        if (x >= self.width or y >= self.height) return;
        const w = @min(width, self.width - x);
        const h = @min(height, self.height - y);
        // Build a contiguous row using exponentially growing, disjoint
        // copies. Avoid per-pixel clipping and offset calculations in the
        // framebuffer hot path (especially expensive under emulated GOP).
        const row_bytes = w * 4;
        for (0..h) |dy| {
            const offset = (y + dy) * self.pitch + x * 4;
            const row = self.pixels[offset..][0..row_bytes];
            @memcpy(row[0..4], &color);
            var filled: usize = 4;
            while (filled < row_bytes) {
                const count = @min(filled, row_bytes - filled);
                @memcpy(row[filled..][0..count], row[0..count]);
                filled += count;
            }
        }
    }

    pub fn clear(self: *Surface, color: [4]u8) void {
        self.fillRect(0, 0, self.width, self.height, color);
    }
};

test "surface rejects invalid dimensions and short buffer" {
    var data: [16]u8 = @splat(0);
    try std.testing.expectError(error.InvalidGeometry, Surface.init(&data, 0, 1, 4));
    try std.testing.expectError(error.InvalidGeometry, Surface.init(&data, 2, 1, 4));
    try std.testing.expectError(error.BufferTooSmall, Surface.init(&data, 2, 3, 8));
}

test "pixel respects stride and bounds" {
    var data: [24]u8 = @splat(0);
    var surface = try Surface.init(&data, 2, 2, 12);
    surface.pixel(1, 1, .{ 1, 2, 3, 4 });
    surface.pixel(2, 1, .{ 9, 9, 9, 9 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, data[16..20]);
    try std.testing.expectEqual(@as(u8, 0), data[20]);
}

test "rectangle clips at right and bottom edges" {
    var data: [64]u8 = @splat(0);
    var surface = try Surface.init(&data, 4, 4, 16);
    surface.fillRect(3, 3, 100, 100, .{ 7, 8, 9, 10 });
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9, 10 }, data[60..64]);
    try std.testing.expectEqual(@as(u8, 0), data[56]);
}

test "bulk rectangle fill preserves pitch and clips edges" {
    var data: [5 * 24]u8 = @splat(0x7e);
    var surface = try Surface.init(&data, 5, 5, 24);
    surface.fillRect(1, 1, 3, 3, .{ 1, 2, 3, 4 });
    for (0..5) |y| {
        for (0..5) |x| {
            const offset = y * 24 + x * 4;
            const expected: [4]u8 = if (x >= 1 and x < 4 and y >= 1 and y < 4)
                .{ 1, 2, 3, 4 }
            else
                .{ 0x7e, 0x7e, 0x7e, 0x7e };
            try std.testing.expectEqualSlices(u8, &expected, data[offset..][0..4]);
        }
        try std.testing.expectEqualSlices(u8, &.{ 0x7e, 0x7e, 0x7e, 0x7e }, data[y * 24 + 20 ..][0..4]);
    }
    surface.fillRect(4, 4, std.math.maxInt(usize), std.math.maxInt(usize), .{ 9, 8, 7, 6 });
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, data[4 * 24 + 16 ..][0..4]);
}
