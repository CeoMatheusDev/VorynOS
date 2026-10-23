//************************************************************************//
//  physical.zig                                                          //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! The physical memory manager of the kernel.
//!
//! The manager keeps a bitmap of the pages of the physical address space. A
//! page is marked as used when it is reserved by the firmware, when it
//! belongs to the kernel image or when it was handed out by the manager.
//!
//! The bitmap describes the manageable physical address space, as determined
//! from the firmware memory map during initialization. The manager supports
//! physical memory beyond 4 GiB by sizing the bitmap according to the actual
//! reported memory, rather than a fixed compile-time constant.

const std = @import("std");
const voryn = @import("voryn_shared");

const handoff = voryn.handoff;

/// Size of a page.
pub const page_size: u64 = handoff.page_size;

/// The lowest physical address that the manager hands out.
///
/// The first megabyte of a PC holds the structures of the firmware, the
/// interrupt vector table and the area of ROM of the cards of the bus. The
/// firmware reports part of that area as ordinary memory, but the kernel
/// never uses it.
pub const minimum_address: u64 = 1024 * 1024;

/// Maximum manageable address space (1 tebibyte).
///
/// The bitmap covers the full range so the manager supports physical memory
/// beyond 4 GiB up to 1 TiB. The bitmap size is 32 KiB (1 TiB / 4 KiB per page / 8).
pub const max_manageable_address: u64 = 1024 * 1024 * 1024 * 1024;

/// Size of the bitmap in bytes, covering the full 1 TiB address space.
///
/// Each bit represents one page (4 KiB), so the bitmap has 1 TiB / 4 KiB / 8 = 32 KiB.
/// 32 KiB = 32 * 1024 = 32768 bytes, covering 32768 * 8 = 262144 pages = 1 TiB / 4 KiB.
pub const max_bitmap_size: usize = 32768;

/// Maximum number of pages the bitmap can track.
pub const max_pages: u32 = @as(u32, max_bitmap_size * 8);

/// Summary of the state of the manager.
pub const Statistics = struct {
    /// Pages of ordinary memory that the firmware reported.
    total_pages: u32 = 0,
    /// Pages of ordinary memory that are in use.
    used_pages: u32 = 0,
    /// Pages of ordinary memory that are free.
    free_pages: u32 = 0,
    /// Highest physical address that the manager knows about.
    highest_address: u64 = 0,
};

/// The physical memory manager.
pub const Manager = struct {
    /// The bitmap, one bit per page: a set bit marks a used page.
    /// The bitmap covers the full 1 TeBibyte address space (32 KiB bitmap).
    /// At runtime, only the pages reported by the firmware memory map are
    /// considered valid; pages beyond the manageable limit are treated as used.
    bitmap: [max_bitmap_size]u8 = @splat(0),
    /// The state of the manager.
    statistics: Statistics = .{},
    /// The next page that the manager tries to hand out.
    hint: u32 = 0,

    /// The number of pages in the manageable address space, as reported by
    /// the firmware memory map during initialization.
    total_pages: u32 = 0,

    /// Prepares the manager with the memory map of the firmware.
    ///
    /// The regions that are not ordinary memory are marked as used, the
    /// ordinary memory is marked as free. The bitmap size is fixed at 32 KiB
    /// to cover the full 1 TiB address space, so the manager supports
    /// physical memory beyond 4 GiB up to 1 TiB.
    pub fn init(self: *Manager, map: []const handoff.MemoryDescriptor) void {
        // Everything starts as **used**: the only pages that the manager
        // hands out are the pages that the firmware described as ordinary
        // memory. The pages that the firmware did not describe are not
        // memory that anyone knows about, and handing them out is a bug
        // waiting to happen.
        self.bitmap = @splat(0xFF);
        self.statistics = .{};
        self.hint = 0;
        self.total_pages = 0;

        // Compute the total number of manageable pages from the firmware
        // memory map. The bitmap covers the full 1 TiB address space, but
        // only pages within the reported ordinary memory are considered free.
        var total_pages: u32 = 0;
        var highest_address: u64 = 0;

        // The ordinary memory is freed first...
        for (map) |region| {
            if (!region.isUsableRam()) continue;

            // Cut the region at the end of the manageable address space.
            const end = @min(region.endAddress(), max_manageable_address);
            if (end <= region.physical_start) continue;

            const first_page: u32 = @as(u32, @intCast(region.physical_start / page_size));
            const last_page: u32 = @as(u32, @intCast((end + page_size - 1) / page_size));

            // Clamp to bitmap capacity.
            const effective_last: u32 = @as(u32, @min(@as(u64, last_page), @as(u64, max_bitmap_size * 8)));
            const count: u32 = effective_last - first_page;
            if (count > 0) {
                self.statistics.total_pages += count;
                total_pages += count;
                self.markRange(first_page, effective_last, false);
            }

            if (end > highest_address) {
                highest_address = end;
            }
        }

        // Also count pages from regions that are not ordinary memory but
        // still need to be tracked as used (reserved, MMIO, etc.).
        // These are already marked as used (0xFF) in the bitmap init, but we
        // track the highest address for diagnostics.
        for (map) |region| {
            if (region.isUsableRam()) continue;

            const end = @min(region.endAddress(), max_manageable_address);
            if (end <= region.physical_start) continue;

            const first_page: u32 = @as(u32, @intCast(region.physical_start / page_size));
            const last_page: u32 = @as(u32, @intCast((end + page_size - 1) / page_size));

            const effective_last: u32 = @as(u32, @min(@as(u64, last_page), @as(u64, max_bitmap_size * 8)));
            self.markRange(first_page, effective_last, true);

            if (end > highest_address) {
                highest_address = end;
            }
        }

        self.total_pages = total_pages;
        self.statistics.total_pages = total_pages;

        // Every page of ordinary memory starts free, and the reservation
        // of the first megabyte is what takes the first ones out of the
        // count.
        // The bitmap was initialized to all 1s (used). We now mark the
        // ordinary memory pages as free (0 bits). The reserve of the first
        // megabyte will set those pages back to used.
        // At this point, free_pages equals total_pages because all ordinary
        // memory pages start free.
        self.statistics.free_pages = self.statistics.total_pages;

        // The first megabyte is never handed out.
        //
        // The reservation **counts** the pages it marks, and the count is
        // what makes the account close: `total = used + free` is a truth at
        // every moment, because only a page that was **free** is counted,
        // and the only free page is the one of ordinary memory that nobody
        // is using.
        self.reserve(0, minimum_address);
    }

    /// Marks a range of pages as used.
    ///
    /// The page that was already in use is not counted again, and a page
    /// that is **not** ordinary memory is not counted either: the count is
    /// the one of the ordinary memory pages that were free and became
    /// used.
    pub fn reserve(self: *Manager, address: u64, length: u64) void {
        if (length == 0) return;

        // The end of the range is computed with the check of the overflow,
        // and the range is cut at the end of the manageable address space.
        const end = std.math.add(u64, address, length) catch max_manageable_address;
        if (end <= address) return;

        const first_page: u32 = @as(u32, @intCast(address / page_size));
        const last_page: u32 = @as(u32, @intCast((@min(end, max_manageable_address) + page_size - 1) / page_size));

        var page: u32 = first_page;
        while (page < last_page and page < max_pages) : (page += 1) {
            if (!self.isPageUsed(page)) {
                self.setUsed(page, true);
                self.statistics.used_pages += 1;
                self.statistics.free_pages -= 1;
            }
        }
    }

    /// Hands out a page, or returns null when there is no free page.
    ///
    /// The search starts at the hint, which keeps the allocations close
    /// together, and wraps around when it reaches the end of the space.
    pub fn allocate(self: *Manager) ?u64 {
        var page = self.hint;
        var attempts: u32 = 0;
        while (attempts < max_pages) : (attempts += 1) {
            if (page >= max_pages) page = 0;
            if (!self.isPageUsed(page)) {
                self.setUsed(page, true);
                self.statistics.used_pages += 1;
                self.statistics.free_pages -= 1;
                self.hint = page + 1;
                return @as(u64, page) * page_size;
            }
            page += 1;
        }

        return null;
    }

    /// Returns a page to the manager.
    pub fn free(self: *Manager, address: u64) void {
        if (address % page_size != 0) return;
        const page: u32 = @as(u32, @intCast(address / page_size));
        if (page >= max_pages) return;
        if (!self.isPageUsed(page)) return;

        self.setUsed(page, false);
        self.statistics.used_pages -= 1;
        self.statistics.free_pages += 1;
        if (page < self.hint) self.hint = page;
    }

    /// True when the page that holds `address` is in use.
    pub fn isUsed(self: *const Manager, address: u64) bool {
        if (address % page_size != 0) return true;
        const page: u32 = @as(u32, @intCast(address / page_size));
        if (page >= max_pages) return true;
        return self.isPageUsed(page);
    }

    fn isPageUsed(self: *const Manager, page: u32) bool {
        const mask: u8 = @as(u8, 1) << @intCast(page % 8);
        return self.bitmap[page / 8] & mask != 0;
    }

    fn setUsed(self: *Manager, page: u32, used: bool) void {
        const mask: u8 = @as(u8, 1) << @intCast(page % 8);
        if (used) {
            self.bitmap[page / 8] |= mask;
        } else {
            self.bitmap[page / 8] &= ~mask;
        }
    }

    fn markRange(self: *Manager, first_page: u32, last_page: u32, used: bool) void {
        var page: u32 = first_page;
        while (page < last_page and page < max_pages) : (page += 1) {
            self.setUsed(page, used);
        }
    }
};

/// The manager of the kernel.
pub var manager: Manager = .{};

const testing = std.testing;

test "the bitmap marks the reserved regions and frees the ordinary memory" {
    var test_manager: Manager = .{};

    // The map is the one of a real machine: the ordinary memory starts
    // **above** the first megabyte, which the firmware never hands to the
    // kernel.
    const map = [_]handoff.MemoryDescriptor{
        .{
            .memory_type = .reserved,
            .physical_start = 0,
            .page_count = 16,
        },
        .{
            .memory_type = .conventional,
            .physical_start = 0x100000,
            .page_count = 16,
        },
        .{
            .memory_type = .memory_mapped_io,
            .physical_start = 0x200000,
            .page_count = 4,
        },
    };

    test_manager.init(&map);

    // The reserved and the device region are in use, the ordinary memory is
    // free.
    try testing.expect(test_manager.isUsed(0));
    try testing.expect(test_manager.isUsed(0x200000));
    try testing.expect(!test_manager.isUsed(0x100000));

    const page = test_manager.allocate().?;
    try testing.expectEqual(@as(u64, 0x100000), page);
    try testing.expect(test_manager.isUsed(0x100000));

    test_manager.free(page);
    try testing.expect(!test_manager.isUsed(0x100000));
}

test "the first megabyte is never handed out" {
    var test_manager: Manager = .{};

    // The firmware describes the ordinary memory of the first megabyte,
    // and the manager refuses that part.
    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0,
        .page_count = 512,
    }};
    test_manager.init(&map);

    try testing.expect(test_manager.isUsed(0));
    try testing.expect(test_manager.isUsed(0xFFFFF));
    try testing.expect(!test_manager.isUsed(0x100000));

    // The first page that is handed out is **above** the first megabyte.
    const page = test_manager.allocate().?;
    try testing.expectEqual(@as(u64, 0x100000), page);
}

test "the pages that the firmware did not describe are never handed out" {
    var test_manager: Manager = .{};

    // The map describes the ordinary memory, and the space above it is not
    // described: nobody knows what is there, and the manager does not hand
    // out a page that nobody described.
    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0x100000,
        .page_count = 16,
    }};
    test_manager.init(&map);

    var pages: [16]u64 = undefined;
    for (&pages) |*page| {
        page.* = test_manager.allocate().?;
    }

    for (pages) |page| {
        try testing.expect(page >= 0x100000);
        try testing.expect(page < 0x110000);
    }

    // There is no free page left, and the manager does not invent one.
    try testing.expect(test_manager.allocate() == null);
}

test "the count of the pages always closes" {
    var test_manager: Manager = .{};

    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0x100000,
        .page_count = 64,
    }};
    test_manager.init(&map);

    // `total = used + free` is a truth at every moment.
    try testing.expectEqual(
        test_manager.statistics.total_pages,
        test_manager.statistics.used_pages + test_manager.statistics.free_pages,
    );

    const page = test_manager.allocate().?;
    try testing.expectEqual(
        test_manager.statistics.total_pages,
        test_manager.statistics.used_pages + test_manager.statistics.free_pages,
    );

    test_manager.reserve(0x200000, 0x4000);
    try testing.expectEqual(
        test_manager.statistics.total_pages,
        test_manager.statistics.used_pages + test_manager.statistics.free_pages,
    );

    test_manager.free(page);
    try testing.expectEqual(
        test_manager.statistics.total_pages,
        test_manager.statistics.used_pages + test_manager.statistics.free_pages,
    );
}

test "reserving a range marks every page of the range" {
    var test_manager: Manager = .{};

    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0x100000,
        .page_count = 64,
    }};
    test_manager.init(&map);

    test_manager.reserve(0x104000, 0x4000);
    try testing.expect(test_manager.isUsed(0x104000));
    try testing.expect(test_manager.isUsed(0x107000));
    try testing.expect(!test_manager.isUsed(0x108000));
    try testing.expect(!test_manager.isUsed(0x103000));
}

test "the manager hands out every free page exactly once" {
    var test_manager: Manager = .{};

    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0x100000,
        .page_count = 8,
    }};
    test_manager.init(&map);

    var pages: [8]u64 = undefined;
    for (&pages) |*page| {
        page.* = test_manager.allocate().?;
    }

    // All eight pages are in use, the next allocation fails.
    try testing.expect(test_manager.allocate() == null);

    for (pages) |page| {
        test_manager.free(page);
    }

    try testing.expect(test_manager.allocate() != null);
}