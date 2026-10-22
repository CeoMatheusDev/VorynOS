//************************************************************************//
//  memory.zig                                                            //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Acquisition and normalisation of the UEFI memory map.
//!
//! The firmware reports the physical memory layout through
//! `EFI_BOOT_SERVICES.GetMemoryMap`. The loader converts the firmware
//! descriptors into the VorynOS `MemoryDescriptor` layout, which is the one
//! described by the boot handoff contract, and keeps the map key that is
//! required to leave the firmware behind.
//!
//! ## Descriptor size
//!
//! The firmware decides the size of one descriptor and reports it in the
//! `DescriptorSize` output of `GetMemoryMap`. Two sizes are observed in
//! practice: 40 bytes (the size of `EFI_MEMORY_DESCRIPTOR` as described by
//! the UEFI specification) and 48 bytes, used by the OVMF build that the
//! automated tests run on, which appends one additional word to the
//! structure. The fields themselves keep the same offsets in both cases, so
//! the loader reads the fields by offset and ignores whatever the firmware
//! appends. The descriptor size is never assumed, it is always the one
//! reported by the firmware.

const std = @import("std");
const uefi = std.os.uefi;
const voryn = @import("voryn_shared");

const handoff = voryn.handoff;

/// Offsets of the fields inside a firmware memory descriptor.
const offset_type = 0;
const offset_physical_start = 8;
const offset_virtual_start = 16;
const offset_number_of_pages = 24;
const offset_attribute = 32;

/// Minimum size of a firmware memory descriptor.
const minimum_descriptor_size = 40;

/// A snapshot of the firmware memory map.
pub const Map = struct {
    /// Normalised descriptors.
    descriptors: []handoff.MemoryDescriptor,
    /// Key that has to be presented to `ExitBootServices`.
    key: uefi.tables.MemoryMapKey = undefined,
    /// Number of descriptors reported by the firmware.
    count: u32 = 0,
};

/// Errors reported while collecting the memory map.
pub const Error = error{
    /// The firmware reported a map that does not fit into the buffer.
    BufferTooSmall,
    /// The firmware reported a descriptor that is too small to be decoded.
    BadDescriptorSize,
    /// The firmware reported a status that the specification does not
    /// describe for this call.
    UnexpectedStatus,
    /// The firmware rejected the request.
    InvalidParameter,
};

/// Reads the memory map into `scratch` and normalises it into `output`.
///
/// `scratch` receives the raw descriptors of the firmware, `output` receives
/// the normalised descriptors. Both buffers are owned by the caller.
pub fn fetch(
    boot_services: *uefi.tables.BootServices,
    scratch: []u8,
    output: []handoff.MemoryDescriptor,
) Error!Map {
    const info = boot_services.getMemoryMapInfo() catch return error.UnexpectedStatus;
    if (info.descriptor_size < minimum_descriptor_size) return error.BadDescriptorSize;

    const required = info.len * info.descriptor_size;
    if (required > scratch.len) return error.BufferTooSmall;

    const aligned: []align(8) u8 = @alignCast(scratch[0..required]);
    const slice = boot_services.getMemoryMap(aligned) catch |err| switch (err) {
        error.BufferTooSmall => return error.BufferTooSmall,
        error.InvalidParameter => return error.InvalidParameter,
        error.Unexpected => return error.UnexpectedStatus,
    };

    const stride = slice.info.descriptor_size;
    if (stride < minimum_descriptor_size) return error.BadDescriptorSize;
    if (slice.info.len > output.len) return error.BufferTooSmall;

    const base: [*]const u8 = @ptrCast(slice.ptr);

    var count: usize = 0;
    while (count < slice.info.len) : (count += 1) {
        const entry = base[count * stride ..][0..stride];

        output[count] = .{
            .memory_type = @enumFromInt(std.mem.readInt(u32, entry[offset_type..][0..4], .little)),
            .physical_start = std.mem.readInt(u64, entry[offset_physical_start..][0..8], .little),
            .virtual_start = std.mem.readInt(u64, entry[offset_virtual_start..][0..8], .little),
            .page_count = std.mem.readInt(u64, entry[offset_number_of_pages..][0..8], .little),
            .attributes = std.mem.readInt(u64, entry[offset_attribute..][0..8], .little),
        };
    }

    return .{
        .descriptors = output[0..count],
        .key = slice.info.key,
        .count = @intCast(count),
    };
}
