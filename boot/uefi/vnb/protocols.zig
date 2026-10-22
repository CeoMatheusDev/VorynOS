//************************************************************************//
//  protocols.zig                                                         //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! UEFI protocol bindings used by the Voryn Native Boot loader.
//!
//! The loader talks to the firmware through the UEFI interfaces defined by
//! the UEFI specification. Only the subset that the boot chain actually needs
//! is declared here, but every structure follows the specification layout
//! exactly, including the reserved padding fields.
//!
//! ## The revision header
//!
//! The UEFI specification describes the protocol structures with an
//! `EFI_REVISION` header as the first member. Real firmware is not
//! consistent about it: the OVMF build used for the automated tests exposes
//! the Graphics Output Protocol and the Simple Text Output Protocol *without*
//! that header. This was confirmed experimentally - calling the member at
//! offset eight produced the expected output while the member at offset
//! sixteen did not, and the first eight bytes of the structure hold a
//! function pointer instead of the revision value `0x00010000`.
//!
//! Instead of assuming one of the two variants, the loader detects the layout
//! at runtime. `Protocol` keeps two pointers: the *body*, which is the
//! structure without the revision header and therefore gives the correct
//! address for every member, and the *this* pointer, which is the address
//! the firmware expects to receive as the first argument of every callback.
//! Passing the body pointer as `This` would make the firmware read the
//! members at the wrong offsets, therefore the two pointers are kept
//! separate.
//!
//! The generic UEFI tables (`EFI_SYSTEM_TABLE`, `EFI_BOOT_SERVICES`,
//! `EFI_RUNTIME_SERVICES`) are provided by the Zig standard library
//! (`std.os.uefi.tables`), which is used as the ABI reference layer for
//! those tables. All boot *policy* - which modes to pick, which file to
//! load, when to leave the firmware - is implemented by VorynOS itself.

const std = @import("std");
const uefi = std.os.uefi;

pub const Guid = uefi.Guid;
pub const Status = uefi.Status;
pub const Handle = uefi.Handle;
pub const cc = uefi.cc;

/// Value of an `EFI_REVISION` header of a version 1.0 protocol.
pub const revision_value: u64 = 0x0001_0000;

/// Returns true when the protocol structure at `base` starts with the
/// `EFI_REVISION` header.
pub fn hasRevisionHeader(base: *const anyopaque) bool {
    const value: *const u64 = @ptrCast(@alignCast(base));
    return value.* == revision_value;
}

/// A protocol with a detected layout.
///
/// `Body` is the structure of the protocol *without* the revision header, so
/// that every member of `Body` has the same address the firmware uses.
pub fn Protocol(comptime Body: type) type {
    return struct {
        const Self = @This();

        /// Address the firmware expects as the `This` argument.
        this: *anyopaque,
        /// Structure of the protocol without the revision header.
        body: *Body,

        /// Wraps the interface pointer returned by the firmware.
        pub fn init(base: *anyopaque) Self {
            const body: *Body = if (hasRevisionHeader(base))
                @ptrCast(@alignCast(@as([*]u8, @ptrCast(base)) + @sizeOf(u64)))
            else
                @ptrCast(@alignCast(base));
            return .{ .this = base, .body = body };
        }

        /// Returns the `This` pointer for a callback of the protocol.
        ///
        /// The address is the one the firmware handed out, never the address
        /// of the body, because the firmware reads its own members relative
        /// to this pointer.
        pub fn thisPointer(self: *const Self) *Body {
            return @ptrCast(@alignCast(self.this));
        }
    };
}

/// `EFI_LOADED_IMAGE_PROTOCOL`, without the revision header.
pub const LoadedImageBody = extern struct {
    parent_handle: Handle = undefined,
    system_table: *anyopaque = undefined,
    device_handle: ?Handle = null,
    file_path: ?*anyopaque = null,
    reserved: ?*anyopaque = null,
    load_options_size: u32 = 0,
    load_options: ?*anyopaque = null,
    image_base: [*]u8 = undefined,
    image_size: u64 = 0,
    image_code_type: u32 = 0,
    image_data_type: u32 = 0,
    unload: *const fn (*LoadedImageBody, Handle) callconv(cc) Status = undefined,
};

/// `EFI_LOADED_IMAGE_PROTOCOL_GUID`.
pub const loaded_image_guid: Guid align(8) = .{
    .time_low = 0x5B1B31A1,
    .time_mid = 0x9562,
    .time_high_and_version = 0x11D2,
    .clock_seq_high_and_reserved = 0x8E,
    .clock_seq_low = 0x3F,
    .node = [_]u8{ 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B },
};

/// `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`, without the revision header.
pub const SimpleFileSystemBody = extern struct {
    open_volume: *const fn (*const SimpleFileSystemBody, **FileBody) callconv(cc) Status = undefined,
};

/// `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID`.
pub const simple_file_system_guid: Guid align(8) = .{
    .time_low = 0x964E5B22,
    .time_mid = 0x6459,
    .time_high_and_version = 0x11D2,
    .clock_seq_high_and_reserved = 0x8E,
    .clock_seq_low = 0x39,
    .node = [_]u8{ 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B },
};

/// Open modes accepted by `EFI_FILE_PROTOCOL.Open`.
pub const FileOpenMode = struct {
    pub const read: u64 = 0x0000000000000001;
    pub const write: u64 = 0x0000000000000002;
    pub const create: u64 = 0x8000000000000000;
};

/// `EFI_FILE_PROTOCOL`, without the revision header.
pub const FileBody = extern struct {
    open: *const fn (*const FileBody, **FileBody, [*:0]const u16, u64, u64) callconv(cc) Status = undefined,
    close: *const fn (*FileBody) callconv(cc) Status = undefined,
    delete: *const fn (*FileBody) callconv(cc) Status = undefined,
    read: *const fn (*FileBody, *usize, [*]u8) callconv(cc) Status = undefined,
    write: *const fn (*FileBody, *usize, [*]const u8) callconv(cc) Status = undefined,
    get_position: *const fn (*const FileBody, *u64) callconv(cc) Status = undefined,
    set_position: *const fn (*const FileBody, u64) callconv(cc) Status = undefined,
    get_info: *const fn (*const FileBody, *align(8) const Guid, *usize, ?[*]u8) callconv(cc) Status = undefined,
    set_info: *const fn (*const FileBody, *align(8) const Guid, usize, [*]const u16) callconv(cc) Status = undefined,
    flush: *const fn (*FileBody) callconv(cc) Status = undefined,
};

/// `EFI_FILE_INFO_ID`, used to query the size of a file.
pub const file_info_guid: Guid align(8) = .{
    .time_low = 0x09576E92,
    .time_mid = 0x6D3F,
    .time_high_and_version = 0x11D2,
    .clock_seq_high_and_reserved = 0x8E,
    .clock_seq_low = 0x39,
    .node = [_]u8{ 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B },
};

/// `EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL`, without the revision header.
pub const SimpleTextOutputBody = extern struct {
    reset: *const fn (*SimpleTextOutputBody, bool) callconv(cc) Status = undefined,
    output_string: *const fn (*SimpleTextOutputBody, [*:0]const u16) callconv(cc) Status = undefined,
    test_string: *const fn (*SimpleTextOutputBody, [*:0]const u16) callconv(cc) Status = undefined,
    query_mode: *const fn (*SimpleTextOutputBody, u32, *usize, *u32) callconv(cc) Status = undefined,
    set_mode: *const fn (*SimpleTextOutputBody, u32) callconv(cc) Status = undefined,
    set_attribute: *const fn (*SimpleTextOutputBody, u32) callconv(cc) Status = undefined,
    clear: *const fn (*SimpleTextOutputBody) callconv(cc) Status = undefined,
};

/// `EFI_GRAPHICS_OUTPUT_PROTOCOL`, without the revision header.
pub const GraphicsOutputBody = extern struct {
    query_mode: *const fn (*const GraphicsOutputBody, u32, *usize, *?*anyopaque) callconv(cc) Status = undefined,
    set_mode: *const fn (*GraphicsOutputBody, u32) callconv(cc) Status = undefined,
    blt: *const fn (*GraphicsOutputBody, ?[*]u8, u32, usize, usize, usize, usize, usize, usize, usize) callconv(cc) Status = undefined,
    mode: *GraphicsOutputMode = undefined,
};

/// `EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID`.
pub const graphics_output_guid: Guid align(8) = .{
    .time_low = 0x9042A9DE,
    .time_mid = 0x23DC,
    .time_high_and_version = 0x4A38,
    .clock_seq_high_and_reserved = 0x96,
    .clock_seq_low = 0xFB,
    .node = [_]u8{ 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A },
};

/// `EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE_INFORMATION`.
pub const GraphicsOutputMode = extern struct {
    max_mode: u32 = 0,
    mode: u32 = 0,
    info: *GraphicsOutputModeInfo = undefined,
    /// Size of the `EFI_GRAPHICS_OUTPUT_MODE_INFORMATION` structure.
    size_of_info: u64 = 0,
    frame_buffer_base: u64 = 0,
    frame_buffer_size: u64 = 0,
};

/// `EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE_INFORMATION` payload.
pub const GraphicsOutputModeInfo = extern struct {
    version: u32 = 0,
    horizontal_resolution: u32 = 0,
    vertical_resolution: u32 = 0,
    pixel_format: u32 = 0,
    pixel_information: PixelBitmask = .{},
    pixels_per_scan_line: u32 = 0,
};

/// `EFI_PIXEL_BITMASK`.
pub const PixelBitmask = extern struct {
    red_mask: u32 = 0,
    green_mask: u32 = 0,
    blue_mask: u32 = 0,
    reserved_mask: u32 = 0,
};

/// Pixel format identifiers of `EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE_INFORMATION`.
pub const PixelFormat = struct {
    pub const red_green_blue_reserved_8_bit_per_color: u32 = 0;
    pub const blue_green_red_reserved_8_bit_per_color: u32 = 1;
    pub const bit_mask: u32 = 2;
    pub const blt_only: u32 = 3;
};

/// Locates a protocol on `handle` and returns its raw interface pointer.
pub fn handleProtocol(
    boot_services: *uefi.tables.BootServices,
    handle: Handle,
    guid: *const Guid,
) ?*anyopaque {
    var interface: ?*anyopaque = null;
    const status = boot_services._handleProtocol(handle, guid, &interface);
    if (status != .success) return null;
    return interface;
}

/// Locates the first instance of a protocol in the system and returns its raw
/// interface pointer.
pub fn locateProtocol(
    boot_services: *uefi.tables.BootServices,
    guid: *const Guid,
) ?*anyopaque {
    var interface: ?*anyopaque = null;
    const status = boot_services._locateProtocol(guid, null, @ptrCast(&interface));
    if (status != .success) return null;
    return interface;
}
