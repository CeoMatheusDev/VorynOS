// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! The physical memory manager of the kernel.
//!
//! The manager keeps a bitmap of the pages of the physical address space. A
//! page is marked as used when it is reserved by the firmware, when it
//! belongs to the kernel image or when it was handed out by the manager.
//!
//! The bitmap describes the first four gigabytes of the physical address
//! space, which covers every machine the kernel supports today. The limit is
//! a compile time constant: a machine with more memory than that is
//! reported as an error during the initialisation instead of being silently
//! ignored.

const std = @import("std");
const voryn = @import("voryn_shared");

const handoff = voryn.handoff;

/// Size of a page.
pub const page_size: u64 = handoff.page_size;

/// The physical address space described by the bitmap.
pub const managed_address_space: u64 = 4 * 1024 * 1024 * 1024;

/// Number of pages described by the bitmap.
pub const managed_pages: u32 = @intCast(managed_address_space / page_size);

/// Size of the bitmap in bytes.
pub const bitmap_size: usize = (managed_pages + 7) / 8;

/// The lowest physical address that the manager hands out.
///
/// The first megabyte of a PC holds the structures of the firmware, the
/// interrupt vector table and the area of ROM of the cards of the bus. The
/// firmware reports part of that area as ordinary memory, but the kernel
/// never uses it.
pub const minimum_address: u64 = 1024 * 1024;

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
    bitmap: [bitmap_size]u8 = @splat(0),
    /// The state of the manager.
    statistics: Statistics = .{},
    /// The next page that the manager tries to hand out.
    hint: u32 = 0,

    /// Prepares the manager with the memory map of the firmware.
    ///
    /// The regions that are not ordinary memory are marked as used, the
    /// ordinary memory is marked as free.
    pub fn init(self: *Manager, map: []const handoff.MemoryDescriptor) void {
        self.bitmap = @splat(0);
        self.statistics = .{};
        self.hint = 0;

        for (map) |region| {
            const first_page = @as(u32, @intCast(region.physical_start / page_size));
            const last_page = @as(u32, @intCast((region.endAddress() + page_size - 1) / page_size));

            if (region.isUsableRam()) {
                self.statistics.total_pages += last_page - first_page;
                if (region.endAddress() > self.statistics.highest_address) {
                    self.statistics.highest_address = region.endAddress();
                }
            } else {
                // Everything that is not ordinary memory is reserved.
                self.markRange(first_page, last_page, true);
            }
        }

        // The first megabyte is never handed out.
        self.reserve(0, minimum_address);

        self.statistics.used_pages = 0;
        self.statistics.free_pages = self.statistics.total_pages;
    }

    /// Marks a range of pages as used.
    pub fn reserve(self: *Manager, address: u64, length: u64) void {
        if (length == 0) return;
        const first_page = @as(u32, @intCast(address / page_size));
        const last_page = @as(u32, @intCast((address + length + page_size - 1) / page_size));

        var page = first_page;
        while (page < last_page and page < managed_pages) : (page += 1) {
            if (!self.isPageUsed(page)) {
                self.setUsed(page, true);
                self.statistics.used_pages += 1;
            }
        }

        self.statistics.free_pages = self.statistics.total_pages - self.statistics.used_pages;
    }

    /// Hands out a page, or returns null when there is no free page.
    ///
    /// The search starts at the hint, which keeps the allocations close
    /// together, and wraps around when it reaches the end of the space.
    pub fn allocate(self: *Manager) ?u64 {
        var page = self.hint;
        var attempts: u32 = 0;
        while (attempts < managed_pages) : (attempts += 1) {
            if (page >= managed_pages) page = 0;
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

    /// Hands out a page below `limit`, or returns null when there is no
    /// free page under the limit.
    ///
    /// The low allocations exist for the bounce pages of the paging module:
    /// frames that the tables of the kernel map by identity without
    /// colliding with the image, which sits above the megabyte that the
    /// manager never hands out.
    pub fn allocateBelow(self: *Manager, limit: u64) ?u64 {
        if (limit > managed_address_space) return null;
        const last_page: u32 = @intCast(limit / page_size);

        var page = self.hint;
        var attempts: u32 = 0;
        while (attempts < last_page) : (attempts += 1) {
            if (page >= last_page) page = minimum_address / page_size;
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
        const page = @as(u32, @intCast(address / page_size));
        if (page >= managed_pages) return;
        if (!self.isPageUsed(page)) return;

        self.setUsed(page, false);
        self.statistics.used_pages -= 1;
        self.statistics.free_pages += 1;
        if (page < self.hint) self.hint = page;
    }

    /// True when the page that holds `address` is in use.
    pub fn isUsed(self: *const Manager, address: u64) bool {
        if (address % page_size != 0) return true;
        const page = @as(u32, @intCast(address / page_size));
        if (page >= managed_pages) return true;
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
        var page = first_page;
        while (page < last_page and page < managed_pages) : (page += 1) {
            self.setUsed(page, used);
        }
    }
};

/// The manager of the kernel.
pub var manager: Manager = .{};

const testing = std.testing;

test "the bitmap marks the reserved regions and frees the ordinary memory" {
    var test_manager: Manager = .{};

    const map = [_]handoff.MemoryDescriptor{
        .{
            .memory_type = .reserved,
            .physical_start = 0,
            .page_count = 16,
        },
        .{
            .memory_type = .conventional,
            .physical_start = 0x10000,
            .page_count = 16,
        },
        .{
            .memory_type = .memory_mapped_io,
            .physical_start = 0x20000,
            .page_count = 4,
        },
    };

    test_manager.init(&map);

    // The reserved and the device region are in use, the ordinary memory is
    // free.
    try testing.expect(test_manager.isUsed(0));
    try testing.expect(test_manager.isUsed(0x20000));
    try testing.expect(!test_manager.isUsed(0x10000));

    const page = test_manager.allocate().?;
    try testing.expectEqual(@as(u64, 0x10000), page);
    try testing.expect(test_manager.isUsed(0x10000));

    test_manager.free(page);
    try testing.expect(!test_manager.isUsed(0x10000));
}

test "reserving a range marks every page of the range" {
    var test_manager: Manager = .{};

    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0,
        .page_count = 64,
    }};
    test_manager.init(&map);

    test_manager.reserve(0x4000, 0x4000);
    try testing.expect(test_manager.isUsed(0x4000));
    try testing.expect(test_manager.isUsed(0x7000));
    try testing.expect(!test_manager.isUsed(0x8000));
    try testing.expect(!test_manager.isUsed(0x3000));
}

test "the manager hands out every free page exactly once" {
    var test_manager: Manager = .{};

    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0,
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
