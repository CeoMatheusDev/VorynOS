//************************************************************************//
//  paging.zig                                                            //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

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
///
/// A level 1 table describes two megabytes, therefore the pool describes
/// `level1_count` times two megabytes of identity mapping. The image of the
/// kernel grows, and a table that cannot describe the whole image makes the
/// kernel unable to boot, so the pool is sized with room to grow.
const level1_count = 32;

/// Number of address spaces of the processes that the kernel supports.
pub const max_process_spaces = 4;

/// The root tables of the address spaces of the processes.
///
/// A process has an address space of its own: the root table of the space
/// holds the tables of the kernel — copied from the tables of the kernel, so
/// that the image and the framebuffer stay visible in both directions of the
/// switch — and a private chain that reaches the window of the user mode.
/// Two processes therefore never share a mapping of the pages of the user,
/// and that is what makes the copy between two processes a real copy.
var process_root_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The private third level tables of the address spaces of the processes.
var process_level3_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The private second level tables of the address spaces of the processes.
var process_level2_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The private first level tables with the pages of the user mode.
var process_level1_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The address spaces that the kernel handed out.
var process_spaces: [max_process_spaces]AddressSpace = @splat(.{});

/// The number of address spaces that the kernel handed out.
var process_spaces_used: usize = 0;

/// An address space of a process.
///
/// The space holds the tables of the kernel and the private chain of the
/// window of the user mode. The address of the space is stable, because the
/// root table is referred to by pointer.
pub const AddressSpace = struct {
    /// The root table of the space.
    root: *PageTable = undefined,
    /// The private table of the third level.
    level3: *PageTable = undefined,
    /// The private table of the second level, the one of the window.
    level2: *PageTable = undefined,
    /// The private table of the first level, the one of the window.
    level1: *PageTable = undefined,
    /// The identifier of the process that owns the space.
    id: u32 = 0,
};

/// The number of pages of the window of the user mode of a process.
pub const window_pages: u64 = 4;

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
        // The entry of a large page lives in the table of the second level,
        // and its index is the index of the page of two megabytes inside
        // that table. The index of the page in the whole address space is
        // not the same one, and using it writes the entry in the wrong
        // place as soon as the range is not inside the first gigabyte of
        // its own table.
        const address = large * large_page_size;
        const level2_index = (address >> 21) & 511;

        if (level2.entries[level2_index] & Flags.present != 0) {
            // The entry is already described by another mapping, and the
            // kernel does not overwrite a mapping that it did not build.
            if (level2.entries[level2_index] & Flags.large == 0) {
                return error.RangeTooLarge;
            }
            continue;
        }

        level2.entries[level2_index] = address | flags | Flags.large;
    }
}

/// Maps a range of the kernel by identity, with small pages.
///
/// A table of the first level describes two megabytes, therefore a range
/// that is larger than that needs more than one table, and a range that
/// crosses the boundary of two megabytes needs the table of the chunk that
/// follows. The function walks the range and hands out a table for every
/// chunk, so that the image of the kernel is described as a whole and not
/// only its first two megabytes.
///
/// The limit of a single table was a defect: the image of the kernel grows
/// with every increment, and a kernel that is not able to describe its own
/// image does not boot at all.
fn mapKernelRange(virtual: u64, length: u64) Error!void {
    if (length == 0) return;

    const end = std.math.add(u64, virtual, length) catch return error.RangeTooLarge;
    if (end < virtual) return error.RangeTooLarge;

    var address = virtual;
    while (address < end) {
        const level4_index = (address >> 39) & 511;
        const level3_index = (address >> 30) & 511;
        const level2_index = (address >> 21) & 511;

        // The kernel only uses the first gigabyte of the address space for
        // the tables of the hierarchy, which covers 512 gigabytes.
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

        // The table of the first level covers the chunk of two megabytes
        // that holds the address, and the walk stops at the end of the
        // chunk or at the end of the range.
        const chunk_start = (address >> 21) << 21;
        const chunk_end = @min(end, chunk_start + large_page_size);

        while (address < chunk_end) : (address += page_size) {
            const index = (address >> 12) & 511;
            level1.entries[index] = (address & ~@as(u64, 0xFFF)) | Flags.present | Flags.writable;
        }
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
    //
    // The image is described as a whole: the range can be larger than the
    // two megabytes of a single table of the first level, and the function
    // hands out a table for every chunk that the range covers.
    if (kernel_end < kernel_base) return error.RangeTooLarge;
    try mapKernelRange(kernel_base, kernel_end - kernel_base);

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
    active_space = null;
    cpu.writeCr3(addressOf(&level4));
}

/// The address of the root table, used for the diagnostics.
pub fn rootAddress() u64 {
    return addressOf(&level4);
}

/// Creates an address space for a process.
///
/// The space starts as a copy of the space of the kernel: the image of the
/// kernel and the framebuffer stay mapped in the space of the process,
/// because the kernel runs in the space of the process that it interrupted,
/// and because the stack of the kernel of the task lives in the image. The
/// window of the user mode is the only region that the process owns, and it
/// starts empty.
///
/// The window has to live in the first gigabyte of the address space, the
/// same region where the image of the kernel is mapped, and it has to use a
/// table of the second level of its own. The kernel checks the placement
/// before it calls the function, and the function refuses a window that
/// does not satisfy the requirement.
pub fn createAddressSpace(window: u64) ?*AddressSpace {
    if (process_spaces_used >= max_process_spaces) return null;

    // The window lives in the first gigabyte, and the table of the second
    // level of the first gigabyte holds the image of the kernel. The window
    // needs a table of the first level of its own, and the table of the
    // second level of the space is a copy of the one of the kernel.
    const level3_index = (window >> 30) & 511;
    const level2_index = (window >> 21) & 511;
    if (level3_index != 0) return null;

    const index = process_spaces_used;
    process_spaces_used += 1;

    const space = &process_spaces[index];
    const root = &process_root_pool[index];
    const private_level3 = &process_level3_pool[index];
    const private_level2 = &process_level2_pool[index];
    const private_level1 = &process_level1_pool[index];

    // The private tables start as a copy of the tables of the kernel, so
    // that the image of the kernel and the framebuffer stay mapped in the
    // space of the process.
    root.* = level4;
    private_level3.* = level3;
    private_level2.* = tableOf(level3.entries[0]).*;

    // The window of the user mode has a table of the first level of its
    // own, and the entry of the table of the second level of the space
    // points at it.
    private_level1.* = .{};
    private_level2.entries[level2_index] = addressOf(private_level1) | table_flags;

    // The root table of the space points at the private table of the third
    // level, and the private table of the third level at the private table
    // of the second level.
    root.entries[0] = addressOf(private_level3) | table_flags;
    private_level3.entries[0] = addressOf(private_level2) | table_flags;

    space.* = .{
        .root = root,
        .level3 = private_level3,
        .level2 = private_level2,
        .level1 = private_level1,
        .id = @intCast(index),
    };

    return space;
}

/// Maps a page of the user mode in the space of a process.
///
/// The page is mapped with the bit that allows the access from the third
/// level of privilege, and the table of the first level of the space is the
/// one that receives the entry.
pub fn mapUserPageIn(space: *AddressSpace, virtual: u64, physical: u64) Error!void {
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    if (space.level2.entries[level2_index] & Flags.present == 0) {
        return error.OutOfTables;
    }

    space.level1.entries[level1_index] =
        (physical & ~@as(u64, 0xFFF)) | Flags.present | Flags.writable | Flags.user;
}

/// Makes the space of a process the active one.
pub fn activateSpace(space: *const AddressSpace) void {
    active_space = space;
    cpu.writeCr3(addressOf(space.root));
}

/// The address space that is active.
///
/// The function returns null when the space of the kernel is the active one,
/// which is the space of the tasks of the kernel.
pub fn activeSpace() ?*const AddressSpace {
    return active_space;
}

/// Records the address space that is active, without writing the register
/// of the tables.
///
/// The scheduler uses the function when it hands the space of the entering
/// task to the switch: the switch writes the register of the tables, and
/// the module has to know which space is the active one.
pub fn setActiveSpace(space: ?*const AddressSpace) void {
    active_space = space;
}

/// The address space that is active.
var active_space: ?*const AddressSpace = null;

/// The address of the root table of the space of a process.
pub fn spaceRoot(space: *const AddressSpace) u64 {
    return addressOf(space.root);
}

/// The address space of a process, by its identifier.
///
/// The identifier of a space is the order in which the kernel handed it
/// out, and the function returns null when the identifier does not exist.
pub fn spaceById(id: u64) ?*AddressSpace {
    if (id >= process_spaces_used) return null;
    return &process_spaces[@intCast(id)];
}

/// Checks whether a range of virtual addresses belongs to the user mode in
/// the space of a process.
///
/// The function walks the private tables of the space and verifies that
/// every page of the range is present, that the page carries the bit of
/// user, and that the page is writable when the range has to be written.
pub fn isUserRangeIn(
    space: *const AddressSpace,
    virtual: u64,
    length: u64,
    writable: bool,
) bool {
    if (length == 0) return false;

    const end = std.math.add(u64, virtual, length) catch return false;
    if (end < virtual) return false;

    var address = virtual;
    while (address < end) {
        if (!isUserPageIn(space, address, writable)) return false;

        const next = std.math.add(u64, address, page_size) catch return false;
        if (next <= address) return false;
        address = next;
    }

    return true;
}

/// Checks whether a virtual address is in a page of the user mode in the
/// space of a process.
fn isUserPageIn(space: *const AddressSpace, virtual: u64, writable: bool) bool {
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry2 = space.level2.entries[level2_index];
    if (entry2 & Flags.present == 0) return false;
    if (entry2 & Flags.large != 0) return false;

    const entry1 = space.level1.entries[level1_index];
    if (entry1 & Flags.present == 0) return false;
    if (entry1 & Flags.user == 0) return false;
    if (writable and entry1 & Flags.writable == 0) return false;

    return true;
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

/// Checks whether a range of virtual addresses belongs to the user mode.
///
/// The function walks the hierarchy of the tables and verifies that every
/// page of the range is present, that the page carries the bit of user, and
/// that the page is writable when the range has to be written. A range of
/// zero length is never valid.
///
/// When a process is running, the check walks the tables of the space of the
/// process, because the pages of the user mode live in that space and in no
/// other. The kernel uses the function before it touches a buffer that the
/// user mode handed over: a user program can point to any address, and the
/// kernel may not trust it.
pub fn isUserRange(virtual: u64, length: u64, writable: bool) bool {
    if (active_space) |space| {
        return isUserRangeIn(space, virtual, length, writable);
    }

    if (length == 0) return false;

    // The end of the range is exclusive, and the addition is checked
    // because an overflow would make the range look valid.
    const end = std.math.add(u64, virtual, length) catch return false;
    if (end < virtual) return false;

    var address = virtual;
    while (address < end) {
        if (!isUserPage(address, writable)) return false;

        // The next page, without overflow at the end of the space.
        const next = std.math.add(u64, address, page_size) catch return false;
        if (next <= address) return false;
        address = next;
    }

    return true;
}

/// Checks whether a virtual address is in a page of the user mode.
fn isUserPage(virtual: u64, writable: bool) bool {
    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry4 = level4.entries[level4_index];
    if (entry4 & Flags.present == 0) return false;

    const entry3 = tableOf(entry4).entries[level3_index];
    if (entry3 & Flags.present == 0) return false;

    const entry2 = tableOf(entry3).entries[level2_index];
    if (entry2 & Flags.present == 0) return false;
    if (entry2 & Flags.large != 0) {
        // A large page of the user mode covers the whole range, and the
        // kernel never maps one for the user.
        return entry2 & Flags.user != 0 and (!writable or entry2 & Flags.writable != 0);
    }

    const entry1 = tableOf(entry2).entries[level1_index];
    if (entry1 & Flags.present == 0) return false;
    if (entry1 & Flags.user == 0) return false;
    if (writable and entry1 & Flags.writable == 0) return false;

    return true;
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
