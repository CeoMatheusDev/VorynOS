// VorynOS F6: bridge the bounded window manager to the opaque compositor.
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
//! No allocations or framebuffer mappings. Colors are selected by the trusted
//! compositor, not by untrusted client pointers.
const std = @import("std");
const wm = @import("window_manager.zig");
const compositor = @import("compositor.zig");
const raster = @import("raster.zig");

pub const Palette = struct {
    background: [4]u8,
    active: [4]u8,
    inactive: [4]u8,
};

/// Convert bottom-to-top window order into a bounded compositor snapshot.
/// The returned count identifies initialized entries in the caller's array.
pub fn snapshot(manager: *const wm.Manager, out: *[wm.capacity]compositor.Window, palette: Palette) usize {
    for (0..manager.count) |index| {
        const slot = &manager.slots[manager.order[index]];
        const handle: wm.Handle = .{ .slot = manager.order[index], .generation = slot.generation };
        const focused = if (manager.focused) |focus|
            focus.slot == handle.slot and focus.generation == handle.generation
        else
            false;
        out[index] = .{
            .x = slot.window.x,
            .y = slot.window.y,
            .width = slot.window.width,
            .height = slot.window.height,
            .color = if (focused) palette.active else palette.inactive,
            .visible = slot.window.visible,
        };
    }
    return manager.count;
}

pub fn render(surface: *raster.Surface, manager: *const wm.Manager, palette: Palette) void {
    var windows: [wm.capacity]compositor.Window = undefined;
    const count = snapshot(manager, &windows, palette);
    compositor.compose(surface, palette.background, windows[0..count]);
}

pub fn renderDirty(surface: *raster.Surface, manager: *const wm.Manager, palette: Palette, dirty: compositor.Rect) usize {
    var windows: [wm.capacity]compositor.Window = undefined;
    const count = snapshot(manager, &windows, palette);
    return compositor.composeDirty(surface, palette.background, windows[0..count], dirty);
}

test "render preserves z-order and highlights focused window" {
    var manager = wm.Manager{};
    const bottom = try manager.create(.{ .owner = 1, .x = 0, .y = 0, .width = 3, .height = 3 });
    _ = try manager.create(.{ .owner = 2, .x = 1, .y = 1, .width = 2, .height = 2 });
    const palette: Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var pixels: [64]u8 = @splat(0);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    render(&surface, &manager, palette);
    try std.testing.expectEqualSlices(u8, &.{ 3, 3, 3, 3 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, pixels[20..24]);
    try manager.raise(bottom, 1);
    render(&surface, &manager, palette);
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, pixels[20..24]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[60..64]);
}

test "dirty rendering changes only selected pixels" {
    var manager = wm.Manager{};
    _ = try manager.create(.{ .owner = 1, .x = 0, .y = 0, .width = 4, .height = 4 });
    const palette: Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 5, 5, 5, 5 },
        .inactive = .{ 2, 2, 2, 2 },
    };
    var pixels: [64]u8 = @splat(0xaa);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    try std.testing.expectEqual(@as(usize, 1), renderDirty(&surface, &manager, palette, .{
        .x = 2, .y = 2, .width = 1, .height = 1,
    }));
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 5, 5 }, pixels[40..44]);
    try std.testing.expectEqual(@as(u8, 0xaa), pixels[0]);
}
