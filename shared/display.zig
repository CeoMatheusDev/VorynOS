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

//! Contract of the display metadata exposed to the user mode.
//!
//! The structure describes the visible surface only. It deliberately does
//! not contain the physical base address or the size of the framebuffer
//! mapping: the user mode has no access to the MMIO window, and a later
//! `present` call is the only path that writes pixels.

const std = @import("std");

/// Version of the display metadata structure.
pub const info_version: u32 = 1;

/// The firmware reported a 32 bpp mode with the usual RGB channel order.
pub const pixel_format_rgb32: u32 = 0;
/// The firmware reported a 32 bpp mode with the channel order reversed.
pub const pixel_format_bgr32: u32 = 1;
/// The firmware did not report a usable pixel layout.
pub const pixel_format_unknown: u32 = 0xFFFF_FFFF;

/// Description of the visible display handed over by the firmware.
///
/// The layout is part of the ABI: a field is never reordered, removed or
/// resized. A future version appends fields after `reserved` and raises
/// `info_version`. This kernel requires a length of at least the current
/// size, writes exactly the current size and returns it; a caller built
/// against a larger future version still works because the extra bytes are
/// left untouched.
pub const DisplayInfo = extern struct {
    /// Must be `info_version`.
    version: u32 = info_version,
    /// Visible width in pixels.
    width: u32 = 0,
    /// Visible height in pixels.
    height: u32 = 0,
    /// Number of bytes between the start of two consecutive rows.
    pitch: u32 = 0,
    /// Bits per pixel.
    bits_per_pixel: u32 = 0,
    /// One of the `pixel_format_*` values.
    pixel_format: u32 = pixel_format_unknown,
    /// Channel masks, meaningful for 32 bpp modes.
    red_mask: u32 = 0,
    green_mask: u32 = 0,
    blue_mask: u32 = 0,
    /// Channel shifts, meaningful for 32 bpp modes.
    red_shift: u8 = 0,
    green_shift: u8 = 0,
    blue_shift: u8 = 0,
    /// Reserved for a future version; must be zero in version 1.
    reserved: u8 = 0,
};

test "display metadata layout is stable" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(DisplayInfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(DisplayInfo, "version"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(DisplayInfo, "width"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(DisplayInfo, "height"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(DisplayInfo, "pitch"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(DisplayInfo, "bits_per_pixel"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(DisplayInfo, "pixel_format"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(DisplayInfo, "red_mask"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(DisplayInfo, "red_shift"));
    try std.testing.expectEqual(@as(usize, 39), @offsetOf(DisplayInfo, "reserved"));
}

test "display metadata defaults are explicit" {
    const info: DisplayInfo = .{};
    try std.testing.expectEqual(info_version, info.version);
    try std.testing.expectEqual(@as(u32, 0), info.width);
    try std.testing.expectEqual(pixel_format_unknown, info.pixel_format);
    try std.testing.expectEqual(@as(u8, 0), info.reserved);
}
