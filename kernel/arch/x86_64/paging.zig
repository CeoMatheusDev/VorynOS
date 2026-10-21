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
//!     processor;
//!   * the pages of the tasks that run in user mode, mapped with the bit
//!     that allows the access from the third level of privilege.
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

/// Number of level 2 tables that the kernel provides.
const level2_count = 8;

/// Number of level 1 tables that the kernel provides.
const level1_count = 32;

/// The level 4 table, the root of the hierarchy.
var level4: PageTable align(4096) = .{};

/// The level 3 table.
var level3: PageTable align(4096) = .{};

/// The level 2 tables, one for each gigabyte of the address space.
var level2_pool: [level2_count]PageTable align(4096) = @splat(.{});

/// The level 1 tables, one for each two megabytes of the address space.
var level1_pool: [level1_count]PageTable align(4096) = @splat(.{});

/// The next level 2 table that is handed out.
var level2_used: usize = 0;

/// The next level 1 table that is handed out.
var level1_used: usize = 0;

/// Errors reported while building the tables.
pub const Error = error{
    /// The tables cannot describe the requested range.
    RangeTooLarge,
    /// The kernel does not have enough tables for the requested mapping.
    OutOfTables,
};

/// Maps a page of the kernel, with the same address in the physical and in
/// the virtual address space.
pub fn mapKernelPage(virtual: u64, physical: u64) Error!void {
    return mapPage(virtual, physical, Flags.present | Flags.writable);
}

/// Maps a page that the tasks in user mode may access.
pub fn mapUserPage(virtual: u64, physical: u64) Error!void {
    return mapPage(virtual, physical, Flags.present | Flags.writable | Flags.user);
}

/// Maps a page.
///
/// The entries of the upper levels always carry the bit that allows the
/// access from the user mode: the processor checks the bit in every level,
/// and only the entry of the page itself decides whether the access is
/// allowed. The pages of the kernel do not have the bit, therefore they
/// stay inaccessible from the user mode.
fn mapPage(virtual: u64, physical: u64, flags: u64) Error!void {
    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    // The kernel only uses the first gigabyte of the address space for the
    // tables of the hierarchy, which covers 512 gigabytes.
    if (level4_index != 0) return error.RangeTooLarge;

    if (level4.entries[level4_index] & Flags.present == 0) {
        level4.entries[level4_index] = addressOf(&level3) | table_flags;
    }
    if (level3.entries[level3_index] & Flags.present == 0) {
        const table = allocateLevel2() orelse return error.OutOfTables;
        level3.entries[level3_index] = addressOf(table) | table_flags;
    }

    const level2 = tableOf(level3.entries[level3_index]);
    if (level2.entries[level2_index] & Flags.present == 0) {
        const table = allocateLevel1() orelse return error.OutOfTables;
        level2.entries[level2_index] = addressOf(table) | table_flags;
    }

    const level1 = tableOf(level2.entries[level2_index]);
    level1.entries[level1_index] = (physical & ~@as(u64, 0xFFF)) | flags;
}

/// The attributes of the entries of the upper levels of the hierarchy.
const table_flags: u64 = Flags.present | Flags.writable | Flags.user;

/// Maps a range of large pages of the kernel.
fn mapLargeRange(virtual: u64, length: u64, flags: u64) Error!void {
    const first = virtual / large_page_size;
    const last = (virtual + length + large_page_size - 1) / large_page_size;

    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;

    if (level4_index != 0) return error.RangeTooLarge;

    if (level4.entries[level4_index] & Flags.present == 0) {
        level4.entries[level4_index] = addressOf(&level3) | table_flags;
    }
    if (level3.entries[level3_index] & Flags.present == 0) {
        const table = allocateLevel2() orelse return error.OutOfTables;
        level3.entries[level3_index] = addressOf(table) | table_flags;
    }

    const level2 = tableOf(level3.entries[level3_index]);
    var large = first;
    while (large < last) : (large += 1) {
        level2.entries[large % 512] = (large * large_page_size) | flags | Flags.large;
    }
}

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
    level2_pool = @splat(.{});
    level1_pool = @splat(.{});
    level2_used = 0;
    level1_used = 0;

    // The kernel image, by identity, with small pages.
    const first_page = kernel_base / page_size;
    const last_page = (kernel_end + page_size - 1) / page_size;
    if (last_page - first_page > 512) return error.RangeTooLarge;

    const level2_index = (kernel_base >> 21) & 511;
    const level1 = allocateLevel1() orelse return error.OutOfTables;
    const level2 = allocateLevel2() orelse return error.OutOfTables;

    level4.entries[0] = addressOf(&level3) | table_flags;
    level3.entries[0] = addressOf(level2) | table_flags;
    level2.entries[level2_index] = addressOf(level1) | table_flags;

    var page = first_page;
    while (page < last_page) : (page += 1) {
        level1.entries[page % 512] = (page * page_size) | Flags.present | Flags.writable;
    }

    // The framebuffer, by identity, with large pages and without the cache.
    if (framebuffer_base != 0 and framebuffer_size != 0) {
        try mapLargeRange(
            framebuffer_base,
            framebuffer_size,
            Flags.present | Flags.writable | Flags.cache_disabled,
        );
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

/// Describes the mapping of a virtual address.
///
/// The function walks the hierarchy of the tables and reports the entry of
/// every level, so that a wrong mapping can be found without a debugger.
pub fn describe(virtual: u64) void {
    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry4 = level4.entries[level4_index];
    voryn.serial.printLine("[DBG] map 0x{x}: l4[{d}] = 0x{x}", .{ virtual, level4_index, entry4 });
    if (entry4 & Flags.present == 0) return;

    const entry3 = tableOf(entry4).entries[level3_index];
    voryn.serial.printLine("[DBG]        l3[{d}] = 0x{x}", .{ level3_index, entry3 });
    if (entry3 & Flags.present == 0) return;

    const entry2 = tableOf(entry3).entries[level2_index];
    voryn.serial.printLine("[DBG]        l2[{d}] = 0x{x}", .{ level2_index, entry2 });
    if (entry2 & Flags.present == 0) return;
    if (entry2 & Flags.large != 0) {
        voryn.serial.printLine("[DBG]        large page", .{});
        return;
    }

    const entry1 = tableOf(entry2).entries[level1_index];
    voryn.serial.printLine("[DBG]        l1[{d}] = 0x{x} (physical 0x{x}, user {})", .{
        level1_index,
        entry1,
        entry1 & ~@as(u64, 0xFFF),
        (entry1 & Flags.user) != 0,
    });
}

/// The number of entries of the root table that are in use.
pub fn mappedEntries() u32 {
    var count: u32 = 0;
    for (level4.entries) |entry| {
        if (entry & Flags.present != 0) count += 1;
    }
    return count;
}

/// Reserves a level 2 table.
fn allocateLevel2() ?*PageTable {
    if (level2_used >= level2_count) return null;
    const table = &level2_pool[level2_used];
    level2_used += 1;
    return table;
}

/// Reserves a level 1 table.
fn allocateLevel1() ?*PageTable {
    if (level1_used >= level1_count) return null;
    const table = &level1_pool[level1_used];
    level1_used += 1;
    return table;
}

/// Returns the table that an entry of a higher level points at.
fn tableOf(entry: u64) *PageTable {
    const address = entry & ~@as(u64, 0xFFF);
    return @ptrFromInt(address);
}

/// The physical address of a table.
fn addressOf(table: *const PageTable) u64 {
    return @intFromPtr(table);
}
