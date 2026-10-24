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

/// Version of the presentation request structure.
pub const present_version: u32 = 1;

/// Upper bound of the pixel buffer of one presentation.
///
/// The bound is larger than the largest display that the bootloader accepts
/// (2048x2048 at 32 bpp, 16 MiB) and small enough that a call cannot keep
/// the kernel copying an arbitrary amount of memory.
pub const max_present_length: u64 = 64 * 1024 * 1024;

/// Request of the `present` call.
///
/// The buffer belongs to the caller and is read, never written, by the
/// kernel. The destination rectangle is relative to the visible display,
/// and `stride` is the number of bytes between the start of two rows of the
/// caller's buffer. The layout is part of the ABI.
pub const PresentRequest = extern struct {
    /// Must be `present_version`.
    version: u32 = present_version,
    /// Left edge of the destination rectangle, in pixels.
    x: u32 = 0,
    /// Top edge of the destination rectangle, in pixels.
    y: u32 = 0,
    /// Width of the rectangle, in pixels.
    width: u32 = 0,
    /// Height of the rectangle, in pixels.
    height: u32 = 0,
    /// Bytes between the start of two consecutive rows of `buffer`.
    stride: u32 = 0,
    /// One of the `pixel_format_*` values; must match the display.
    pixel_format: u32 = pixel_format_unknown,
    /// Reserved for a future version; must be zero in version 1.
    reserved: u32 = 0,
    /// Address of the first byte of the caller's buffer.
    buffer: u64 = 0,
    /// Number of readable bytes in the caller's buffer.
    length: u64 = 0,
};

/// The reasons why a presentation request is refused before any pixel is
/// copied.
pub const PresentError = error{
    /// The request was built against a version that the kernel does not know.
    InvalidVersion,
    /// The rectangle is empty or leaves the visible display.
    InvalidGeometry,
    /// The stride is smaller than one row of the rectangle.
    InvalidStride,
    /// The buffer is smaller than the rows that the request describes.
    InvalidLength,
    /// The display or the request uses a pixel format that `present` does
    /// not support.
    InvalidFormat,
};

/// Checks the request against the visible display.
///
/// The function is pure: it does not read the buffer and does not touch the
/// framebuffer. The kernel calls it after the capability check and after
/// copying the request, before the pixel buffer range check and before any
/// pixel is written. The host tests call it directly.
pub fn validatePresent(request: *const PresentRequest, info: *const DisplayInfo) PresentError!void {
    if (request.version != present_version) return error.InvalidVersion;
    if (request.reserved != 0) return error.InvalidVersion;
    if (request.width == 0 or request.height == 0) return error.InvalidGeometry;

    // The subtraction is safe after the comparison, and it rejects a
    // rectangle that would overflow the 32-bit edges.
    if (request.x >= info.width or request.y >= info.height) return error.InvalidGeometry;
    if (request.width > info.width - request.x) return error.InvalidGeometry;
    if (request.height > info.height - request.y) return error.InvalidGeometry;

    if (info.bits_per_pixel != 32) return error.InvalidFormat;
    if (request.pixel_format != info.pixel_format) return error.InvalidFormat;
    if (request.pixel_format != pixel_format_rgb32 and
        request.pixel_format != pixel_format_bgr32)
    {
        return error.InvalidFormat;
    }

    const row_bytes = std.math.mul(u32, request.width, 4) catch return error.InvalidGeometry;
    if (request.stride < row_bytes) return error.InvalidStride;

    const required = std.math.mul(u64, request.stride, request.height) catch return error.InvalidLength;
    if (request.length < required) return error.InvalidLength;
    if (request.length > max_present_length) return error.InvalidLength;
}

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

test "presentation request layout is stable" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(PresentRequest));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(PresentRequest, "version"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(PresentRequest, "x"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(PresentRequest, "y"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(PresentRequest, "width"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(PresentRequest, "height"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(PresentRequest, "stride"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(PresentRequest, "pixel_format"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(PresentRequest, "reserved"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(PresentRequest, "buffer"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(PresentRequest, "length"));
}

test "presentation request defaults are explicit" {
    const request: PresentRequest = .{};
    try std.testing.expectEqual(present_version, request.version);
    try std.testing.expectEqual(@as(u32, 0), request.width);
    try std.testing.expectEqual(pixel_format_unknown, request.pixel_format);
    try std.testing.expectEqual(@as(u64, 0), request.length);
}

fn sampleInfo() DisplayInfo {
    return .{
        .width = 640,
        .height = 480,
        .pitch = 2560,
        .bits_per_pixel = 32,
        .pixel_format = pixel_format_bgr32,
    };
}

fn sampleRequest() PresentRequest {
    return .{
        .x = 10,
        .y = 20,
        .width = 16,
        .height = 8,
        .stride = 64,
        .pixel_format = pixel_format_bgr32,
        .buffer = 0x1000,
        .length = 512,
    };
}

test "a well formed presentation request is accepted" {
    const info = sampleInfo();
    const request = sampleRequest();
    try validatePresent(&request, &info);
}

test "a presentation request of an unknown version is refused" {
    const info = sampleInfo();
    var request = sampleRequest();
    request.version = present_version + 1;
    try std.testing.expectError(error.InvalidVersion, validatePresent(&request, &info));
}

test "a presentation request with a reserved field is refused" {
    const info = sampleInfo();
    var request = sampleRequest();
    request.reserved = 1;
    try std.testing.expectError(error.InvalidVersion, validatePresent(&request, &info));
}

test "a presentation rectangle outside the display is refused" {
    const info = sampleInfo();

    var request = sampleRequest();
    request.x = 630;
    try std.testing.expectError(error.InvalidGeometry, validatePresent(&request, &info));

    request = sampleRequest();
    request.y = 480;
    try std.testing.expectError(error.InvalidGeometry, validatePresent(&request, &info));

    request = sampleRequest();
    request.width = 0;
    try std.testing.expectError(error.InvalidGeometry, validatePresent(&request, &info));

    request = sampleRequest();
    request.height = 0;
    try std.testing.expectError(error.InvalidGeometry, validatePresent(&request, &info));
}

test "a presentation stride smaller than one row is refused" {
    const info = sampleInfo();
    var request = sampleRequest();
    request.stride = 63;
    try std.testing.expectError(error.InvalidStride, validatePresent(&request, &info));
}

test "a presentation buffer smaller than the rows is refused" {
    const info = sampleInfo();
    var request = sampleRequest();
    request.length = 511;
    try std.testing.expectError(error.InvalidLength, validatePresent(&request, &info));
}

test "a presentation on a display that is not 32 bpp is refused" {
    var info = sampleInfo();
    info.bits_per_pixel = 16;
    const request = sampleRequest();
    try std.testing.expectError(error.InvalidFormat, validatePresent(&request, &info));
}

test "a presentation format that does not match the display is refused" {
    const info = sampleInfo();

    var request = sampleRequest();
    request.pixel_format = pixel_format_rgb32;
    try std.testing.expectError(error.InvalidFormat, validatePresent(&request, &info));

    var unknown_info = sampleInfo();
    unknown_info.pixel_format = pixel_format_unknown;
    request = sampleRequest();
    request.pixel_format = pixel_format_unknown;
    try std.testing.expectError(error.InvalidFormat, validatePresent(&request, &unknown_info));
}

test "a presentation buffer above the bound is refused" {
    const info = sampleInfo();
    var request = sampleRequest();
    request.length = max_present_length + 1;
    try std.testing.expectError(error.InvalidLength, validatePresent(&request, &info));
}
