//************************************************************************//
//  compositor.zig                                                        //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

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

/// Recompõe todo o framebuffer; a implementação inicial prioriza
/// previsibilidade. Dirty rectangles são um incremento futuro.
pub fn compose(surface: *raster.Surface, background: [4]u8, windows: []const Window) void {
    surface.clear(background);
    for (windows) |window| {
        if (!window.visible) continue;
        surface.fillRect(window.x, window.y, window.width, window.height, window.color);
    }
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
