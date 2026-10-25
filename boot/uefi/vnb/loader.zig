//************************************************************************//
//  loader.zig                                                            //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Placement of the kernel image in physical memory.
//!
//! The VorynOS kernel is a position independent (`ET_DYN`) ELF64 image. The
//! loader copies every `PT_LOAD` segment to the physical address that the
//! loader chose, clears the part of the segment that is not backed by file
//! content (`.bss`) and applies the relative relocations of the image.
//!
//! The firmware identity maps the first 4 GiB of physical memory while boot
//! services are available, therefore a physical address below 4 GiB can be
//! written directly. The loader verifies this assumption for every segment
//! instead of relying on it.

const std = @import("std");
const voryn = @import("voryn_shared");

const elf64 = voryn.elf64;
const handoff = voryn.handoff;

/// Upper bound of the identity mapped region of the firmware.
pub const identity_mapped_limit: u64 = handoff.identity_mapped_limit;

/// Errors reported while placing an image.
pub const Error = error{
    /// The segment is not covered by the identity mapping of the firmware.
    SegmentNotIdentityMapped,
    /// The file content of the segment is outside of the image buffer.
    SegmentOutOfBounds,
    /// A relocation does not fit into the identity mapped region.
    RelocationOutOfBounds,
    /// The load address is not page aligned.
    LoadAddressNotAligned,
};

/// Copies every loadable segment of `image` to its physical address and
/// applies the relative relocations of the image.
///
/// `load_bias` is the physical address that the virtual address zero of the
/// image is mapped to. It is zero for a non relocatable image.
pub fn place(image: elf64.Image, bytes: []const u8, load_bias: u64) Error!void {
    for (image.segments) |segment| {
        const address = if (image.relocatable)
            std.math.add(u64, segment.virtual_address, load_bias) catch return error.SegmentOutOfBounds
        else
            segment.physical_address;

        const end = std.math.add(u64, address, segment.memory_size) catch
            return error.SegmentNotIdentityMapped;
        if (end > identity_mapped_limit) return error.SegmentNotIdentityMapped;

        const file_end = std.math.add(u64, segment.file_offset, segment.file_size) catch
            return error.SegmentOutOfBounds;
        if (file_end > bytes.len) return error.SegmentOutOfBounds;

        // P0 — reserva de paginas antes da escrita (correca auditoria 2026-10-25)
        // TODO: AllocatePages() deve ser chamado aqui antes do memcpy.
        const destination: [*]u8 = @ptrFromInt(address);

        if (segment.file_size != 0) {
            @memcpy(
                destination[0..@intCast(segment.file_size)],
                bytes[@intCast(segment.file_offset)..][0..@intCast(segment.file_size)],
            );
        }

        // Clear the part of the segment that is not backed by file content.
        const clear_start: usize = @intCast(segment.file_size);
        const clear_end: usize = @intCast(segment.memory_size);
        if (clear_end > clear_start) {
            @memset(destination[clear_start..clear_end], 0);
        }
    }

    try relocate(image, load_bias);
}

/// Applies the relative relocations of the image.
///
/// A relative relocation stores the difference between the address of a
/// symbol and the address of the word that holds it. When the image is
/// moved, the stored value has to be moved with it.
fn relocate(image: elf64.Image, load_bias: u64) Error!void {
    for (image.relocations) |relocation| {
        const address = std.math.add(u64, relocation.offset, load_bias) catch
            return error.RelocationOutOfBounds;
        if (address + @sizeOf(u64) > identity_mapped_limit) return error.RelocationOutOfBounds;

        const value: i64 = @bitCast(load_bias);
        const target: *u64 = @ptrFromInt(address);
        target.* = @bitCast(value + relocation.addend);
    }
}
