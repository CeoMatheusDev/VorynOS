//************************************************************************//
//  display.zig                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Registry of the display metadata handed over by the firmware.
//!
//! The syscall of the user mode reads this registry; the framebuffer base
//! and size stay in the kernel. The registry is written once, during the
//! boot, before the user tasks run, and it is only read afterwards.

const std = @import("std");
const handoff = @import("voryn_shared").handoff;
const contract = @import("voryn_shared").display;

var current: ?contract.DisplayInfo = null;

comptime {
    if (@intFromEnum(handoff.PixelFormat.rgb32) != contract.pixel_format_rgb32) {
        @compileError("the display contract and the handoff disagree on rgb32");
    }
    if (@intFromEnum(handoff.PixelFormat.bgr32) != contract.pixel_format_bgr32) {
        @compileError("the display contract and the handoff disagree on bgr32");
    }
    if (@intFromEnum(handoff.PixelFormat.unknown) != contract.pixel_format_unknown) {
        @compileError("the display contract and the handoff disagree on the unknown format");
    }
}

/// Copies the firmware description into the registry.
///
/// A missing or empty framebuffer clears the registry: the user mode then
/// receives the error of the absent display instead of a structure full of
/// zeros that it could mistake for a real mode.
pub fn install(framebuffer: handoff.FramebufferInfo) void {
    if (framebuffer.base == 0 or
        framebuffer.size == 0 or
        framebuffer.width == 0 or
        framebuffer.height == 0 or
        framebuffer.bits_per_pixel == 0 or
        framebuffer.pitch == 0)
    {
        current = null;
        return;
    }

    current = .{
        .version = contract.info_version,
        .width = framebuffer.width,
        .height = framebuffer.height,
        .pitch = framebuffer.pitch,
        .bits_per_pixel = framebuffer.bits_per_pixel,
        .pixel_format = @intFromEnum(framebuffer.pixel_format),
        .red_mask = framebuffer.red_mask,
        .green_mask = framebuffer.green_mask,
        .blue_mask = framebuffer.blue_mask,
        .red_shift = framebuffer.red_shift,
        .green_shift = framebuffer.green_shift,
        .blue_shift = framebuffer.blue_shift,
        .reserved = 0,
    };
}

/// Clears the registry, for a boot without a framebuffer.
pub fn clear() void {
    current = null;
}

/// Returns a copy of the current metadata, or null when there is no display.
pub fn info() ?contract.DisplayInfo {
    return current;
}

test "display registry copies the firmware metadata" {
    install(.{
        .base = 0x8000_0000,
        .size = 2048 * 2048 * 4,
        .width = 2048,
        .height = 2048,
        .pitch = 8192,
        .bits_per_pixel = 32,
        .pixel_format = .bgr32,
        .red_mask = 0x00FF_0000,
        .green_mask = 0x0000_FF00,
        .blue_mask = 0x0000_00FF,
        .red_shift = 16,
        .green_shift = 8,
        .blue_shift = 0,
    });

    const metadata = info() orelse return error.TestExpectedDisplay;
    try std.testing.expectEqual(contract.info_version, metadata.version);
    try std.testing.expectEqual(@as(u32, 2048), metadata.width);
    try std.testing.expectEqual(@as(u32, 2048), metadata.height);
    try std.testing.expectEqual(@as(u32, 8192), metadata.pitch);
    try std.testing.expectEqual(@as(u32, 32), metadata.bits_per_pixel);
    try std.testing.expectEqual(contract.pixel_format_bgr32, metadata.pixel_format);
    try std.testing.expectEqual(@as(u32, 0x00FF_0000), metadata.red_mask);
    try std.testing.expectEqual(@as(u8, 16), metadata.red_shift);
}

test "display registry rejects an empty framebuffer" {
    install(.{ .width = 0, .height = 0, .bits_per_pixel = 0, .pitch = 0 });
    try std.testing.expectEqual(@as(?contract.DisplayInfo, null), info());
}

test "display registry rejects a framebuffer without a mapping" {
    install(.{
        .base = 0,
        .size = 0,
        .width = 1024,
        .height = 768,
        .pitch = 4096,
        .bits_per_pixel = 32,
    });
    try std.testing.expectEqual(@as(?contract.DisplayInfo, null), info());
}
