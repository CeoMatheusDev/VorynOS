//************************************************************************//
//  memmap.zig                                                            //
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

//! Helpers for the VorynOS memory map.
//!
//! The map is a flat array of `MemoryDescriptor` entries as defined by the
//! boot handoff contract. Every function here is pure so it can be unit
//! tested on the host and reused by the bootloader, the kernel and the
//! future diagnostic tools.

const std = @import("std");
const handoff = @import("handoff.zig");

pub const MemoryDescriptor = handoff.MemoryDescriptor;
pub const MemoryType = handoff.MemoryType;
pub const page_size = handoff.page_size;

/// Summary of the usable memory of a machine.
pub const Summary = struct {
    /// Total amount of ordinary RAM in bytes.
    total_ram: u64 = 0,
    /// Amount of memory reserved by the firmware in bytes.
    reserved: u64 = 0,
    /// Amount of memory mapped I/O in bytes.
    mmio: u64 = 0,
    /// Number of descriptors in the map.
    entries: u32 = 0,
};

/// Returns the descriptor that fully contains `address`, if any.
pub fn findRegion(map: []const MemoryDescriptor, address: u64) ?MemoryDescriptor {
    for (map) |descriptor| {
        const start = descriptor.physical_start;
        const end = descriptor.endAddress();
        if (address >= start and address < end) return descriptor;
    }
    return null;
}

/// Returns true when `[address, address + length)` is entirely backed by
/// ordinary RAM described by `map`.
///
/// The check is overflow safe: an address range that would wrap around the
/// physical address space is rejected.
pub fn isUsableRange(map: []const MemoryDescriptor, address: u64, length: u64) bool {
    if (length == 0) return false;
    const end = std.math.add(u64, address, length) catch return false;
    if (end <= address) return false;

    var cursor = address;
    while (cursor < end) {
        const descriptor = findRegion(map, cursor) orelse return false;
        if (!descriptor.isUsableRam()) return false;
        cursor = descriptor.endAddress();
    }
    return true;
}

/// Returns true when a range can contain an image allocated by the loader.
///
/// UEFI changes pages reserved with `AllocatePages` to `loader_code` or
/// `loader_data` in the final memory map. Those pages are valid backing for
/// the kernel image, but they must remain reserved from the physical allocator
/// after the handoff, so they are deliberately not ordinary usable RAM.
pub fn isKernelBackedRange(map: []const MemoryDescriptor, address: u64, length: u64) bool {
    if (length == 0) return false;
    const end = std.math.add(u64, address, length) catch return false;
    if (end <= address) return false;

    var cursor = address;
    while (cursor < end) {
        const descriptor = findRegion(map, cursor) orelse return false;
        const backed = switch (descriptor.memory_type) {
            .conventional, .persistent_memory, .loader_code, .loader_data => true,
            else => false,
        };
        if (!backed) return false;
        cursor = descriptor.endAddress();
    }
    return true;
}

/// Computes a summary of the memory described by `map`.
pub fn summarize(map: []const MemoryDescriptor) Summary {
    var summary: Summary = .{ .entries = @intCast(map.len) };
    for (map) |descriptor| {
        switch (descriptor.memory_type) {
            .conventional, .persistent_memory => summary.total_ram += descriptor.byteSize(),
            .memory_mapped_io, .pal_code => summary.mmio += descriptor.byteSize(),
            else => summary.reserved += descriptor.byteSize(),
        }
    }
    return summary;
}

/// Finds the first usable RAM region of at least `length` bytes.
///
/// Returns the physical address of the region and the number of pages that
/// satisfy the request, or null when the machine does not have enough
/// contiguous conventional memory.
pub fn findUsableRegion(
    map: []const MemoryDescriptor,
    length: u64,
) ?struct { address: u64, pages: u64 } {
    if (length == 0) return null;

    // Zig 0.17.0: `@divCeil` replaces `std.math.divCeil`.
    // `length` and `page_size` are both u64, and `page_size` is a non-zero
    // constant, so the division is safe. `@divCeil` is defined to panic on
    // overflow, which is the desired behavior here.
    const pages = @divCeil(length, page_size);

    for (map) |descriptor| {
        if (!descriptor.isUsableRam()) continue;
        if (descriptor.page_count < pages) continue;
        return .{ .address = descriptor.physical_start, .pages = pages };
    }
    return null;
}

/// Finds a region of ordinary RAM that can host `size` bytes.
///
/// The returned address is aligned to `alignment`, is not below
/// `minimum_address` and the whole range is guaranteed to be inside a single
/// region of ordinary RAM.
///
/// The lower bound exists because the first megabyte of a PC holds data
/// structures of the firmware that must not be overwritten, even when the
/// firmware reports the region as ordinary memory.
pub fn findLoadRegion(
    map: []const MemoryDescriptor,
    size: u64,
    alignment: u64,
    minimum_address: u64,
) ?u64 {
    if (size == 0 or alignment == 0) return null;

    for (map) |descriptor| {
        if (!descriptor.isUsableRam()) continue;
        if (descriptor.endAddress() <= minimum_address) continue;

        const start = std.mem.alignForward(u64, descriptor.physical_start, alignment);
        if (start < descriptor.physical_start) continue;
        if (start < minimum_address) continue;
        if (descriptor.byteSize() < size) continue;
        if (start + size > descriptor.endAddress()) continue;

        return start;
    }

    return null;
}

test "findLoadRegion respects the alignment and the region size" {
    const map = [_]MemoryDescriptor{
        .{ .memory_type = .conventional, .physical_start = 0x1000, .page_count = 16 },
        .{ .memory_type = .memory_mapped_io, .physical_start = 0x100000, .page_count = 1 },
        .{ .memory_type = .conventional, .physical_start = 0x200000, .page_count = 64 },
    };

    const aligned = findLoadRegion(&map, 0x1000, 0x200000, 0).?;
    try std.testing.expectEqual(@as(u64, 0x200000), aligned);

    const page = findLoadRegion(&map, 0x1000, 0x1000, 0).?;
    try std.testing.expectEqual(@as(u64, 0x1000), page);

    try std.testing.expect(findLoadRegion(&map, 0x1000000, 0x1000, 0) == null);
    try std.testing.expect(findLoadRegion(&map, 0, 0x1000, 0) == null);

    // The lower bound keeps the loader out of the first megabyte: a region
    // that starts **below** the bound is refused, and the first region that
    // starts at or above it is the one that is used.
    try std.testing.expect(findLoadRegion(&map, 0x1000, 0x1000, 0x200001) == null);
    const at = findLoadRegion(&map, 0x1000, 0x1000, 0x200000).?;
    try std.testing.expectEqual(@as(u64, 0x200000), at);
    const above = findLoadRegion(&map, 0x1000, 0x1000, 0x100000).?;
    try std.testing.expectEqual(@as(u64, 0x200000), above);
}

test "findRegion locates the containing descriptor" {
    const map = [_]MemoryDescriptor{
        .{ .memory_type = .reserved, .physical_start = 0x0, .page_count = 1 },
        .{ .memory_type = .conventional, .physical_start = 0x1000, .page_count = 2 },
        .{ .memory_type = .memory_mapped_io, .physical_start = 0x1000000, .page_count = 1 },
    };

    try std.testing.expectEqual(@as(?MemoryDescriptor, map[1]), findRegion(&map, 0x1000));
    try std.testing.expectEqual(@as(?MemoryDescriptor, map[1]), findRegion(&map, 0x2fff));
    try std.testing.expectEqual(@as(?MemoryDescriptor, map[2]), findRegion(&map, 0x1000000));
    try std.testing.expectEqual(@as(?MemoryDescriptor, null), findRegion(&map, 0x3000));
}

test "isUsableRange rejects non RAM and overflowing ranges" {
    const map = [_]MemoryDescriptor{
        .{ .memory_type = .conventional, .physical_start = 0x1000, .page_count = 2 },
        .{ .memory_type = .memory_mapped_io, .physical_start = 0x3000, .page_count = 1 },
    };

    try std.testing.expect(isUsableRange(&map, 0x1000, 0x1000));
    try std.testing.expect(isUsableRange(&map, 0x1000, 0x2000));
    try std.testing.expect(isUsableRange(&map, 0x2000, 0x1000));

    // A range that starts in the ordinary memory and ends in the region of
    // the device is refused.
    try std.testing.expect(!isUsableRange(&map, 0x1000, 0x2001));
    try std.testing.expect(!isUsableRange(&map, 0x2000, 0x1001));
    try std.testing.expect(!isUsableRange(&map, 0x3000, 0x1000));
    try std.testing.expect(!isUsableRange(&map, 0x1000, 0));
    try std.testing.expect(!isUsableRange(&map, std.math.maxInt(u64) - 0x10, 0x100));
}

test "kernel backed range accepts loader pages but ordinary range does not" {
    const map = [_]MemoryDescriptor{
        .{ .memory_type = .loader_data, .physical_start = 0x1000, .page_count = 2 },
        .{ .memory_type = .conventional, .physical_start = 0x3000, .page_count = 2 },
        .{ .memory_type = .reserved, .physical_start = 0x5000, .page_count = 1 },
    };

    try std.testing.expect(!isUsableRange(&map, 0x1000, page_size));
    try std.testing.expect(isKernelBackedRange(&map, 0x1000, 4 * page_size));
    try std.testing.expect(!isKernelBackedRange(&map, 0x1000, 5 * page_size));
    try std.testing.expect(!isKernelBackedRange(&map, std.math.maxInt(u64) - 0x10, 0x100));
}

test "summarize aggregates the map" {
    const map = [_]MemoryDescriptor{
        .{ .memory_type = .conventional, .physical_start = 0x0, .page_count = 4 },
        .{ .memory_type = .reserved, .physical_start = 0x10000, .page_count = 1 },
        .{ .memory_type = .memory_mapped_io, .physical_start = 0x20000, .page_count = 2 },
    };

    const summary = summarize(&map);
    try std.testing.expectEqual(@as(u64, 4 * page_size), summary.total_ram);
    try std.testing.expectEqual(@as(u64, page_size), summary.reserved);
    try std.testing.expectEqual(@as(u64, 2 * page_size), summary.mmio);
    try std.testing.expectEqual(@as(u32, 3), summary.entries);
}

test "findUsableRegion requires a single contiguous region" {
    const map = [_]MemoryDescriptor{
        .{ .memory_type = .conventional, .physical_start = 0x0, .page_count = 2 },
        .{ .memory_type = .reserved, .physical_start = 0x2000, .page_count = 1 },
        .{ .memory_type = .conventional, .physical_start = 0x3000, .page_count = 8 },
    };

    const small = findUsableRegion(&map, 0x1000).?;
    try std.testing.expectEqual(@as(u64, 0x0), small.address);
    try std.testing.expectEqual(@as(u64, 1), small.pages);

    const large = findUsableRegion(&map, 0x4000).?;
    try std.testing.expectEqual(@as(u64, 0x3000), large.address);
    try std.testing.expectEqual(@as(u64, 4), large.pages);

    try std.testing.expect(findUsableRegion(&map, 0x100000) == null);
}
