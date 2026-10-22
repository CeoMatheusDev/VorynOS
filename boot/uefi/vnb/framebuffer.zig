/**************************************************************************/
/*  framebuffer.zig                                                       */
/**************************************************************************/
/*                         This file is part of:                          */
/*                               VorynOS                                  */
/*              https://github.com/CeoMatheusDev/VorynOS                  */
/**************************************************************************/
/* Copyright (C) 2026 VorynOS contributors.                               */
/*                                                                        */
/* SPDX-License-Identifier: GPL-3.0-only                                  */
/**************************************************************************/

//! Framebuffer discovery through the UEFI Graphics Output Protocol.
//!
//! The loader does not implement a graphics driver. It only selects a sane
//! linear framebuffer mode and describes it precisely enough for the kernel
//! to start writing pixels, and for the future Voryn Graphics Runtime to
//! take over.

const std = @import("std");
const uefi = std.os.uefi;
const voryn = @import("voryn_shared");
const protocols = @import("protocols.zig");

const handoff = voryn.handoff;

/// Errors reported while acquiring a framebuffer.
pub const Error = error{
    /// The firmware does not expose the Graphics Output Protocol.
    NoGraphicsOutput,
    /// The firmware did not report a single usable mode.
    NoUsableMode,
};

/// Preferred minimum horizontal resolution.
const preferred_width = 1024;
/// Preferred minimum vertical resolution.
const preferred_height = 768;

/// A candidate graphics mode.
const Candidate = struct {
    number: u32,
    width: u32,
    height: u32,
    bpp: u32,
};

/// Discovers the framebuffer and switches the firmware to a usable mode.
///
/// The loader returns `error.NoGraphicsOutput` when the protocol is missing,
/// which is not fatal: the kernel can still boot without a framebuffer and
/// the caller decides how to report it.
pub fn discover(boot_services: *uefi.tables.BootServices) Error!handoff.FramebufferInfo {
    const interface = protocols.locateProtocol(boot_services, &protocols.graphics_output_guid) orelse
        return error.NoGraphicsOutput;

    // The firmware may or may not prefix the structure with the revision
    // header, the layout is detected at runtime.
    const gop = protocols.Protocol(protocols.GraphicsOutputBody).init(interface);

    const candidate = selectMode(gop) orelse return error.NoUsableMode;
    _ = gop.body.set_mode(gop.thisPointer(), candidate.number);

    const mode = gop.body.mode;
    const info = mode.info;

    var result: handoff.FramebufferInfo = .{
        .base = mode.frame_buffer_base,
        .size = mode.frame_buffer_size,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pitch = info.pixels_per_scan_line * 4,
        .bits_per_pixel = switch (info.pixel_format) {
            protocols.PixelFormat.red_green_blue_reserved_8_bit_per_color,
            protocols.PixelFormat.blue_green_red_reserved_8_bit_per_color,
            protocols.PixelFormat.bit_mask,
            => 32,
            else => 0,
        },
    };

    switch (info.pixel_format) {
        protocols.PixelFormat.red_green_blue_reserved_8_bit_per_color => {
            result.pixel_format = .rgb32;
            result.red_mask = 0x00FF_0000;
            result.green_mask = 0x0000_FF00;
            result.blue_mask = 0x0000_00FF;
            result.red_shift = 16;
            result.green_shift = 8;
            result.blue_shift = 0;
        },
        protocols.PixelFormat.blue_green_red_reserved_8_bit_per_color => {
            result.pixel_format = .bgr32;
            result.red_mask = 0x0000_00FF;
            result.green_mask = 0x0000_FF00;
            result.blue_mask = 0x00FF_0000;
            result.red_shift = 0;
            result.green_shift = 8;
            result.blue_shift = 16;
        },
        protocols.PixelFormat.bit_mask => {
            result.pixel_format = .rgb32;
            result.red_mask = info.pixel_information.red_mask;
            result.green_mask = info.pixel_information.green_mask;
            result.blue_mask = info.pixel_information.blue_mask;
            result.red_shift = maskShift(info.pixel_information.red_mask);
            result.green_shift = maskShift(info.pixel_information.green_mask);
            result.blue_shift = maskShift(info.pixel_information.blue_mask);
        },
        else => {
            result.pixel_format = .unknown;
        },
    }

    return result;
}

/// Returns the index of the lowest set bit of `mask`, or 0 for an empty mask.
fn maskShift(mask: u32) u8 {
    if (mask == 0) return 0;
    return @intCast(@ctz(mask));
}

/// Picks the best available mode.
///
/// Modes are ranked by resolution, preferring at least 1024x768 and 32 bits
/// per pixel. The scan is deterministic: the lowest mode number wins a tie.
fn selectMode(gop: protocols.Protocol(protocols.GraphicsOutputBody)) ?Candidate {
    var best: ?Candidate = null;

    const max_mode = gop.body.mode.max_mode;
    var number: u32 = 0;
    while (number < max_mode) : (number += 1) {
        var size: usize = 0;
        var info: ?*anyopaque = null;
        const status = gop.body.query_mode(gop.thisPointer(), number, &size, &info);
        if (status != .success) continue;

        const mode_info: *const protocols.GraphicsOutputModeInfo = @ptrCast(@alignCast(info orelse continue));

        const candidate: Candidate = .{
            .number = number,
            .width = mode_info.horizontal_resolution,
            .height = mode_info.vertical_resolution,
            .bpp = switch (mode_info.pixel_format) {
                protocols.PixelFormat.red_green_blue_reserved_8_bit_per_color,
                protocols.PixelFormat.blue_green_red_reserved_8_bit_per_color,
                protocols.PixelFormat.bit_mask,
                => 32,
                else => 0,
            },
        };

        if (candidate.bpp != 32) continue;
        if (candidate.width == 0 or candidate.height == 0) continue;

        const current = best orelse {
            best = candidate;
            continue;
        };

        const current_pixels = @as(u64, current.width) * current.height;
        const candidate_pixels = @as(u64, candidate.width) * candidate.height;

        const current_ok = current.width >= preferred_width and current.height >= preferred_height;
        const candidate_ok = candidate.width >= preferred_width and candidate.height >= preferred_height;

        if (candidate_ok and !current_ok) {
            best = candidate;
        } else if (candidate_ok == current_ok and candidate_pixels > current_pixels) {
            best = candidate;
        }
    }

    return best;
}
