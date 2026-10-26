//************************************************************************//
//  compositor.zig                                                        //
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
//! F6: composição determinística de janelas opacas em uma superfície.
//! Sem alocação dinâmica, ponteiros de usuário ou acesso direto ao hardware.
//! A ordem do slice define o z-order: a última janela fica à frente.

const std = @import("std");
const raster = @import("raster.zig");

pub const Window = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    color: [4]u8,
    visible: bool = true,
};

/// Recompõe todo o framebuffer; caminho de inicialização.
pub fn compose(surface: *raster.Surface, background: [4]u8, windows: []const Window) void {
    surface.clear(background);
    for (windows) |window| {
        if (!window.visible) continue;
        surface.fillRect(window.x, window.y, window.width, window.height, window.color);
    }
}

/// Região danificada com extremos exclusivos e aritmética sem overflow.
pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

/// Recompõe somente a interseção da região danificada com a superfície.
/// Não escreve pixels fora do retângulo, mesmo quando janelas o atravessam.
/// Retorna o número de pixels efetivamente redesenhados.
pub fn composeDirty(surface: *raster.Surface, background: [4]u8, windows: []const Window, dirty: Rect) usize {
    if (dirty.x >= surface.width or dirty.y >= surface.height) return 0;
    const w = @min(dirty.width, surface.width - dirty.x);
    const h = @min(dirty.height, surface.height - dirty.y);
    if (w == 0 or h == 0) return 0;

    surface.fillRect(dirty.x, dirty.y, w, h, background);
    const right = dirty.x + w;
    const bottom = dirty.y + h;
    for (windows) |window| {
        if (!window.visible or window.width == 0 or window.height == 0) continue;
        if (window.x >= right or window.y >= bottom) continue;
        const left = @max(dirty.x, window.x);
        const top = @max(dirty.y, window.y);
        // Subtração limitada pela superfície: evita overflow em x + width.
        const window_right = window.x + @min(window.width, surface.width -| window.x);
        const window_bottom = window.y + @min(window.height, surface.height -| window.y);
        const clipped_right = @min(right, window_right);
        const clipped_bottom = @min(bottom, window_bottom);
        if (clipped_right > left and clipped_bottom > top)
            surface.fillRect(left, top, clipped_right - left, clipped_bottom - top, window.color);
    }
    return w * h;
}

test "dirty composition changes only the requested region and keeps z-order" {
    var pixels: [64]u8 = @splat(0xaa);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    const windows = [_]Window{
        .{ .x = 0, .y = 0, .width = 4, .height = 4, .color = .{ 1, 1, 1, 1 } },
        .{ .x = 2, .y = 2, .width = 2, .height = 2, .color = .{ 2, 2, 2, 2 } },
    };
    try std.testing.expectEqual(@as(usize, 4), composeDirty(&surface, .{ 0, 0, 0, 0 }, &windows, .{
        .x = 1, .y = 1, .width = 2, .height = 2,
    }));
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1 }, pixels[20..24]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2 }, pixels[40..44]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, pixels[60..64]);
}

test "dirty composition clips extreme coordinates without overflow" {
    var pixels: [32]u8 = @splat(0x55);
    var surface = try raster.Surface.init(&pixels, 2, 2, 8);
    const windows = [_]Window{
        .{ .x = 1, .y = 1, .width = std.math.maxInt(usize), .height = std.math.maxInt(usize), .color = .{ 7, 7, 7, 7 } },
        .{ .x = std.math.maxInt(usize), .y = 0, .width = 2, .height = 2, .color = .{ 9, 9, 9, 9 } },
    };
    try std.testing.expectEqual(@as(usize, 1), composeDirty(&surface, .{ 0, 0, 0, 0 }, &windows, .{
        .x = 1, .y = 1, .width = std.math.maxInt(usize), .height = std.math.maxInt(usize),
    }));
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 7 }, pixels[12..16]);
    try std.testing.expectEqual(@as(u8, 0x55), pixels[0]);
    try std.testing.expectEqual(@as(usize, 0), composeDirty(&surface, .{ 0, 0, 0, 0 }, &windows, .{
        .x = std.math.maxInt(usize), .y = 0, .width = 1, .height = 1,
    }));
}

test "last window is in front" {
    var pixels: [64]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    const windows = [_]Window{
        .{ .x = 0, .y = 0, .width = 3, .height = 3, .color = .{ 1, 1, 1, 1 } },
        .{ .x = 1, .y = 1, .width = 2, .height = 2, .color = .{ 2, 2, 2, 2 } },
    };
    compose(&surface, .{ 0, 0, 0, 0 }, &windows);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2 }, pixels[20..24]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[60..64]);
}

test "hidden windows do not draw and clipping is safe" {
    var pixels: [32]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 2, 2, 16);
    const windows = [_]Window{
        .{ .x = 0, .y = 0, .width = 2, .height = 2, .color = .{ 9, 9, 9, 9 }, .visible = false },
        .{ .x = 1, .y = 1, .width = 999, .height = 999, .color = .{ 3, 4, 5, 6 } },
    };
    compose(&surface, .{ 1, 0, 0, 0 }, &windows);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 5, 6 }, pixels[20..24]);
}
