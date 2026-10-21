// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! The page tables of the kernel.
//!
//! The kernel replaces the page tables of the firmware with its own. The new
//! tables map only what the kernel needs:
//!
//!   * the image of the kernel, mapped by identity so that the code, the
//!     stack and the data keep their addresses;
//!   * the linear framebuffer, mapped by identity and without the cache, so
//!     that the memory of a device is not served from the cache of the
//!     processor.
//!
//! Everything else is left unmapped. An access to a page that is not mapped
//! raises a page fault, which is the isolation that the kernel needs before
//! it can run untrusted code.
//!
//! The tables use four kilobyte pages for the kernel and two megabyte pages
//! for the framebuffer.

const std = @import("std");
const voryn = @import("voryn_shared");

const cpu = @import("cpu.zig");
const handoff = voryn.handoff;

/// Size of a small page.
pub const page_size: u64 = 4096;

/// Size of a large page.
pub const large_page_size: u64 = 2 * 1024 * 1024;

/// The bits of an entry of a page table.
pub const Flags = struct {
    /// The page is present in the address space.
    pub const present: u64 = 1 << 0;
    /// The page may be written.
    pub const writable: u64 = 1 << 1;
    /// The page may be accessed by user mode.
    pub const user: u64 = 1 << 2;
    /// The write through caching policy.
    pub const write_through: u64 = 1 << 3;
    /// The page is not cached.
    pub const cache_disabled: u64 = 1 << 4;
    /// The entry refers to a large page.
    pub const large: u64 = 1 << 7;
};

/// A page table with 512 entries.
const PageTable = extern struct {
    entries: [512]u64 = @splat(0),
};

/// The level 4 table, the root of the hierarchy.
var level4: PageTable align(4096) = .{};

/// The level 3 table.
var level3: PageTable align(4096) = .{};

/// The level 2 table of the region of the kernel.
var level2_kernel: PageTable align(4096) = .{};

/// The level 2 table of the region of the framebuffer.
var level2_framebuffer: PageTable align(4096) = .{};

/// The level 1 table of the region of the kernel.
var level1_kernel: PageTable align(4096) = .{};

/// Errors reported while building the tables.
pub const Error = error{
    /// The tables cannot describe the requested range.
    RangeTooLarge,
};

/// Prepares the tables of the kernel.
///
/// The image of the kernel is mapped by identity with small pages, the
/// framebuffer with large pages and without the cache.
pub fn setup(
    kernel_base: u64,
    kernel_end: u64,
    framebuffer_base: u64,
    framebuffer_size: u64,
) Error!void {
    level4 = .{};
    level3 = .{};
    level2_kernel = .{};
    level2_framebuffer = .{};
    level1_kernel = .{};

    // The kernel image.
    level4.entries[0] = addressOf(&level3) | Flags.present | Flags.writable;
    level3.entries[0] = addressOf(&level2_kernel) | Flags.present | Flags.writable;

    const first_page = kernel_base / page_size;
    const last_page = (kernel_end + page_size - 1) / page_size;
    if (last_page - first_page > 512) return error.RangeTooLarge;

    // The level 2 table covers one gigabyte, the level 1 table one two
    // megabyte region of it. The index of the entry follows from the address
    // of the region, not from the beginning of the space.
    const kernel_directory_index = (kernel_base >> 21) & 511;
    level2_kernel.entries[kernel_directory_index] = addressOf(&level1_kernel) |
        Flags.present | Flags.writable;

    var page = first_page;
    while (page < last_page) : (page += 1) {
        level1_kernel.entries[page & 511] = (page * page_size) |
            Flags.present | Flags.writable;
    }

    // The framebuffer.
    if (framebuffer_base != 0 and framebuffer_size != 0) {
        const first_large = framebuffer_base / large_page_size;
        const last_large = (framebuffer_base + framebuffer_size + large_page_size - 1) / large_page_size;

        level4.entries[0] = addressOf(&level3) | Flags.present | Flags.writable;
        level3.entries[(first_large >> 9) & 511] = addressOf(&level2_framebuffer) |
            Flags.present | Flags.writable;

        var large = first_large;
        while (large < last_large) : (large += 1) {
            level2_framebuffer.entries[large % 512] = (large * large_page_size) |
                Flags.present | Flags.writable | Flags.large | Flags.cache_disabled;
        }
    }
}

/// Makes the tables of the kernel the active ones.
pub fn activate() void {
    cpu.writeCr3(addressOf(&level4));
}

/// The address of the root table, used for the diagnostics.
pub fn rootAddress() u64 {
    return addressOf(&level4);
}

/// The number of entries of the root table that are in use.
pub fn mappedEntries() u32 {
    var count: u32 = 0;
    for (level4.entries) |entry| {
        if (entry & Flags.present != 0) count += 1;
    }
    return count;
}

/// The physical address of a table.
fn addressOf(table: *const PageTable) u64 {
    return @intFromPtr(table);
}
