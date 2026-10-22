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

/// The root tables of the address spaces of the processes.
///
/// A process has an address space of its own: the root table of the space
/// holds the entry of the kernel — copied from the root table of the
/// kernel hierarchy, so that the image stays visible in both directions of
/// the switch — and a private chain that reaches the window of the user
/// mode at `user_window_base`. Two processes therefore never share a
/// mapping of the user pages, which is what makes the copy between two
/// processes a real copy through physical frames that only one space names
/// at a time.
var process_root_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The private third level tables of the address spaces of the processes.
var process_level3_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The private second level tables of the address spaces of the processes.
var process_level2_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The private first level tables with the pages of the user mode.
var process_level1_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// Number of address spaces of the processes that the kernel supports.
pub const max_process_spaces = 8;

/// The bounce pages that let the kernel read and write the window of a
/// process while another space is active.
///
/// The window of the user mode lives at the same virtual address in every
/// space, so the memory of a process can only be reached through the page
/// tables of its own space. The bounce pages solve the problem without a
/// switch of `CR3`: each one is a frame inside the first megabyte of
/// physical memory, where the tables of the kernel place no mapping of
/// their own — an access to such a frame therefore works in any address
/// space, because every space carries the entry of the kernel, which maps
/// the whole first terabyte by identity down to the last byte of the
/// image. To look at a page of a process, the kernel points the entry of
/// the window of the space at a bounce page, reads or writes the bounce
/// page through the identity mapping, and puts the frame of the process
/// back afterwards.
///
/// The number of pages bounds the work that happens outside the ownership
/// of a space at any moment; the walk over a longer copy takes the pages
/// one after the other.
pub const bounce_page_count = 2;

/// The frames of the bounce pages, filled by `prepareBouncePages`.
var bounce_frames: [bounce_page_count]u64 = undefined;

/// Number of bounce pages that the kernel handed out to a caller.
var bounce_used: usize = 0;

/// Whether the bounce pages were already prepared.
var bounce_ready = false;

/// The lowest physical address that the hierarchy of the kernel names.
///
/// The image is mapped page by page from `kernel_base` up, so no entry of
/// the kernel points below the place where the loader put it — but the
/// kernel does not know that address until `setup` runs. The value stays
/// null until then, and `isFrameUnmappedByKernel` answers conservatively:
/// an unknown limit means that no frame can be called free of mappings.
var kernel_lowest_address: ?u64 = null;

/// Whether a frame is not named by any mapping of the kernel hierarchy.
///
/// A frame at or above the lowest mapped address of the image already has
/// an identity mapping of its own, and adding a second one would give two
/// virtual addresses to the same memory. Below the limit — and only once
/// the limit is known — the frame is free for a new identity entry, which
/// is what the bounce pages need.
fn isFrameUnmappedByKernel(frame: u64) bool {
    const limit = kernel_lowest_address orelse return false;
    return frame < limit;
}

/// The first address of the window of the user mode of a process.
///
/// The default places the window in the low megabytes, below any normal
/// placement of the image; `setup` moves it above the image when the
/// loader put the kernel lower than that, and reports through
/// `windowFramesUsable` whether the frames of the window can still be
/// reached without a switch of `CR3`.
pub var user_window_base: u64 = 0x40_0000;

/// Whether the frames of the window live below the mapping of the image.
///
/// When the placement of the image leaves no room for the window (the
/// frame of a page of the user collides with an entry of the kernel), the
/// views of `borrowPage` cannot guarantee collision free identity, and the
/// feature of the processes stays off until the handoff of the boot places
/// the image higher.
var window_frames_ok = true;

/// Reports whether the window of the user mode has usable frames.
pub fn windowFramesUsable() bool {
    return window_frames_ok;
}

/// The size of the window of the user mode of a process.
pub const user_window_size: u64 = large_page_size;

/// The next root table of a process that is handed out.
var process_roots_used: usize = 0;

/// An address space of a process.
pub const AddressSpace = struct {
    /// The root table of the space.
    level4: *PageTable,
    /// The private table with the pages of the user mode of the space.
    level1: *PageTable,
    /// The private second level table of the chain of the window.
    window_level2: *PageTable,
    /// The index of the window inside the private second level table.
    window_level2_index: usize = 0,
};

/// The address space that is active.
///
/// The scheduler switches it together with the context of the task: a null
/// value means the hierarchy of the kernel itself, which is what the tasks
/// of the kernel run with.
var active_space: ?*const AddressSpace = null;

/// The number of pages that the kernel mapped inside the spaces of the
/// processes, used by the diagnostics and by the boot test.
var process_pages_mapped: u64 = 0;

/// The number of switches between address spaces, counted by `useSpace`.
var space_switches: u64 = 0;

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
    /// The physical allocator has no frame to hand out.
    OutOfMemory,
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
    // Reject unaligned mappings instead of silently rounding the frame down.
    if (virtual % page_size != 0 or physical % page_size != 0) return error.RangeTooLarge;
    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    // The kernel only uses the first gigabyte of the address space for the
    // tables of the hierarchy, which covers 512 gigabytes.
    if (level4_index != 0) return error.RangeTooLarge;

    // The window of the user mode of a process lives inside the range that
    // the chain of the image describes: writing an entry there would hide
    // a page of a process behind the table of the image, and reading one
    // would follow the frame of a process as if it were a table. The
    // private chain of each space answers for those addresses instead.
    if (window_frames_ok and
        virtual >= user_window_base and
        virtual < user_window_base + user_window_size)
    {
        return error.RangeTooLarge;
    }

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

/// Maps a page by identity, in every address space that exists.
///
/// The mapping goes through the generic path of `mapPage`, so it reaches
/// whatever level 1 table covers the address — the table of the image for
/// frames inside it, a fresh pair of tables for frames outside. The entry
/// of the kernel of the root table points at the same hierarchy that the
/// function writes, and the root table of every process carries a copy of
/// that entry, so a page mapped here is reachable from any space without
/// a switch of `CR3`.
///
/// Only frames that no mapping of the kernel already names are accepted:
/// a second virtual address for one piece of memory would break the
/// invariant that the isolation reasoning depends on. The caller uses
/// `isFrameUnmappedByKernel` before asking for the mapping.
///
/// A new process space created after this call inherits the mapping,
/// because the entry of the kernel is copied at the moment of the
/// creation and the chain below it is shared, not duplicated.
pub fn mapKernelIdentityPage(frame: u64) Error!void {
    if (frame % page_size != 0) return error.RangeTooLarge;
    if (!isFrameUnmappedByKernel(frame)) return error.RangeTooLarge;

    // An entry that already exists means another mapping names the frame,
    // or the same frame was mapped twice by mistake. Either way, stop.
    const probe = resolveEntry(frame) orelse {
        try mapPage(frame, frame, Flags.present | Flags.writable);
        return;
    };
    if (probe & Flags.present != 0) return error.RangeTooLarge;

    try mapPage(frame, frame, Flags.present | Flags.writable);
}

/// Walks the hierarchy of the kernel and returns the entry that describes
/// a virtual address, or null when a table of the chain does not exist.
///
/// A large page answers with its own entry: the bit of the large page
/// tells the caller that the address is covered by a bigger mapping.
fn resolveEntry(virtual: u64) ?u64 {
    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    if (level4.entries[level4_index] & Flags.present == 0) return null;
    const level3_table = tableOf(level4.entries[level4_index]);
    if (level3_table.entries[level3_index] & Flags.present == 0) return null;
    const level2_table = tableOf(level3_table.entries[level3_index]);
    const level2_entry = level2_table.entries[level2_index];
    if (level2_entry & Flags.present == 0) return null;
    if (level2_entry & Flags.large != 0) return level2_entry;
    const level1_table = tableOf(level2_entry);
    return level1_table.entries[level1_index];
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
    process_root_pool = @splat(.{});
    process_level3_pool = @splat(.{});
    process_level2_pool = @splat(.{});
    process_level1_pool = @splat(.{});
    level2_used = 0;
    level1_used = 0;
    process_roots_used = 0;
    active_space = null;
    space_switches = 0;
    process_pages_mapped = 0;
    bounce_ready = false;
    bounce_used = 0;
    kernel_lowest_address = kernel_base;

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

    // The window of the user mode lives between the end of the low memory
    // that the loader may hand out and the first page of the image: the
    // frames that the physical manager gives for a window therefore never
    // collide with an entry of the kernel, which is what makes the view of
    // `borrowPage` safe in any address space. When the placement of the
    // image leaves no room for the window, the feature of the processes
    // stays off and the boot continues without it — see `bouncePagesReady`.
    if (user_window_base + user_window_size <= kernel_base) {
        window_frames_ok = true;
    } else {
        window_frames_ok = false;
        user_window_base = (kernel_base + large_page_size - 1) / large_page_size * large_page_size;
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

/// Checks whether a range of virtual addresses belongs to the user mode.
///
/// The function walks the hierarchy of the tables and verifies that every
/// page of the range is present, that the page carries the bit of user, and
/// that the page is writable when the range has to be written. A range of
/// zero length is never valid.
///
/// The kernel uses the function before it touches a buffer that the user
/// mode handed over: a user program can point to any address, and the
/// kernel may not trust it.
pub fn isUserRange(virtual: u64, length: u64, writable: bool) bool {
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

/// Creates an address space for a process.
///
/// The new space owns four tables of its own, taken from pools that only
/// the spaces of the processes use: a root table, one third level table,
/// one second level table and one first level table with the pages of the
/// user mode. The entry `root[0]` is copied from the root table of the
/// kernel, so every mapping that the kernel needs — the image, the serial
/// device, the framebuffer and the tables themselves — stays visible in
/// both directions of the switch.
///
/// The private chain reaches the window of the user mode at
/// `user_window_base`, inside the first terabyte: `root[0] -> private
/// level 3`, `level 3 [0] -> private level 2`, `level 2 [window index] ->
/// private level 1`. The window starts empty: until a page arrives through
/// `mapUserPageIn`, every access of the process to the window raises a
/// page fault, and never reads the memory of another process.
pub fn createAddressSpace() Error!AddressSpace {
    if (process_roots_used >= max_process_spaces) return error.OutOfTables;

    const kernel_entry = level4.entries[0];
    if (kernel_entry & Flags.present == 0) return error.RangeTooLarge;

    const index = process_roots_used;
    process_roots_used += 1;

    const root = &process_root_pool[index];
    const level3_table = &process_level3_pool[index];
    const level2_table = &process_level2_pool[index];
    const user_table = &process_level1_pool[index];
    root.* = .{};
    level3_table.* = .{};
    level2_table.* = .{};
    user_table.* = .{};

    const window_level2_index = (user_window_base >> 21) & 511;

    root.entries[0] = kernel_entry;
    level3_table.entries[0] = addressOf(level2_table) | table_flags;
    level2_table.entries[window_level2_index] = addressOf(user_table) | table_flags;

    return .{ .level4 = root, .level1 = user_table };
}

/// Maps a page of the user mode inside an address space of a process.
///
/// The function only accepts the addresses that the private level 1 table
/// of the space covers, which keeps the pages of a process inside the two
/// megabytes reserved for the user mode of the space.
pub fn mapUserPageIn(space: *const AddressSpace, virtual: u64, physical_frame: u64) Error!void {
    if (virtual % page_size != 0 or physical_frame % page_size != 0) return error.RangeTooLarge;

    // The private table of the space covers exactly the window of the user
    // mode: [user_window_base, user_window_base + user_window_size).
    if (virtual < user_window_base or virtual >= user_window_base + user_window_size) {
        return error.RangeTooLarge;
    }

    const level1_index = (virtual >> 12) & 511;
    if (space.level1.entries[level1_index] & Flags.present == 0) {
        process_pages_mapped += 1;
    }
    space.level1.entries[level1_index] = (physical_frame & ~@as(u64, 0xFFF)) |
        Flags.present | Flags.writable | Flags.user;
}

/// Removes every mapping of the user mode from an address space.
///
/// The frames themselves are returned to the physical manager by the owner
/// of the space; this function only clears the entries, so that a use of
/// the space after the release faults instead of touching freed memory.
pub fn clearAddressSpace(space: *const AddressSpace) void {
    space.level1.entries = @splat(0);
}

/// Activates an address space and remembers it as the active one.
///
/// The switch writes the new root in `CR3`. The architecture invalidates
/// the translations of the old space as part of the write, which is what
/// keeps the pages of a process invisible to another one even when they
/// share the same virtual address. A null space means the hierarchy of the
/// kernel itself, which is what the tasks of the kernel run with.
pub fn useSpace(space: ?*const AddressSpace) void {
    active_space = space;
    space_switches += 1;
    if (space) |value| {
        cpu.writeCr3(addressOf(value.level4));
    } else {
        cpu.writeCr3(addressOf(&level4));
    }
}

/// The counters of the address spaces, for the diagnostics and the boot
/// test: how many switches happened and how many pages of the processes
/// the kernel mapped.
pub const SpaceStatistics = struct {
    /// Switches between address spaces since the boot.
    switches: u64 = 0,
    /// Pages mapped inside the spaces of the processes since the boot.
    pages_mapped: u64 = 0,
    /// Root tables handed out to the processes since the boot.
    spaces_created: usize = 0,
};

/// The state of the address spaces of the processes.
pub fn spaceStatistics() SpaceStatistics {
    return .{
        .switches = space_switches,
        .pages_mapped = process_pages_mapped,
        .spaces_created = process_roots_used,
    };
}

/// The address space that is active.
pub fn currentSpace() ?*const AddressSpace {
    return active_space;
}

/// The physical frame that the page tables of a space name for a virtual
/// address, or null when the address is not mapped.
///
/// The function walks the private chain of the space, exactly like the
/// processor does, and returns the frame behind the entry of the first
/// level. The kernel uses it to read and to write the memory of a process
/// while another space is active: the copy between two processes goes
/// through the frames of each one, because only one window of the user
/// mode can be addressed at a time.
pub fn frameOf(space: *const AddressSpace, virtual: u64) ?u64 {
    if (virtual % page_size != 0) return null;

    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    if (level4_index != 0) return null;

    const entry4 = space.level4.entries[level4_index];
    if (entry4 & Flags.present == 0) return null;

    const entry3 = tableOf(entry4).entries[level3_index];
    if (entry3 & Flags.present == 0) return null;

    const entry2 = tableOf(entry3).entries[level2_index];
    // The chain of a space of a process never carries a large page.
    if (entry2 & Flags.present == 0 or entry2 & Flags.large != 0) return null;

    const entry1 = tableOf(entry2).entries[level1_index];
    if (entry1 & Flags.present == 0) return null;

    return entry1 & ~@as(u64, 0xFFF);
}

/// Checks whether a range belongs to the user mode of the active space.
///
/// The walk uses the tables of the space that is active, never the tables
/// of the kernel: a call that arrives from a process has to be checked
/// against the pages of that process.
pub fn isUserRangeIn(virtual: u64, length: u64, writable: bool) bool {
    return isUserRangeWith(active_space, virtual, length, writable);
}

/// Checks whether a range belongs to the user mode of one space.
///
/// The variant with the space as an argument exists for the system call
/// that copies between two spaces: the destination of the copy belongs to
/// another process, and it has to be checked against the tables of that
/// process, not against the tables of the caller.
pub fn isUserRangeWith(space: ?*const AddressSpace, virtual: u64, length: u64, writable: bool) bool {
    if (length == 0) return false;

    const end = std.math.add(u64, virtual, length) catch return false;
    if (end < virtual) return false;

    var address = virtual;
    while (address < end) : (address += page_size) {
        if (!isUserPageWith(space, address, writable)) return false;
    }

    return true;
}

/// Checks whether a virtual address is in a page of the user mode of a
/// space.
///
/// The walk follows the same chain that `createAddressSpace` builds: the
/// entry of the terabyte copied from the kernel, then the private level 3,
/// level 2 and level 1 tables of the space. Any range outside the window of
/// the user mode is refused, because the shared entry of the kernel never
/// names a page with the bit of the user mode set.
fn isUserPageWith(space: ?*const AddressSpace, virtual: u64, writable: bool) bool {
    const owner = space orelse return false;

    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    if (level4_index != 0) return false;

    const entry4 = owner.level4.entries[level4_index];
    if (entry4 & Flags.present == 0) return false;

    const entry3 = tableOf(entry4).entries[level3_index];
    if (entry3 & Flags.present == 0) return false;

    const entry2 = tableOf(entry3).entries[level2_index];
    if (entry2 & Flags.present == 0) return false;
    // A large page is never part of a space of a process in this kernel.
    if (entry2 & Flags.large != 0) return false;

    const entry1 = tableOf(entry2).entries[level1_index];
    if (entry1 & Flags.present == 0) return false;
    if (entry1 & Flags.user == 0) return false;
    if (writable and entry1 & Flags.writable == 0) return false;

    return true;
}

/// Prepares the bounce pages of the kernel.
///
/// The function takes frames below `kernel_lowest_address` from the given
/// allocator and maps each one by identity in the hierarchy of the kernel,
/// so that a write to the frame reaches it from any address space: every
/// space carries the entry of the kernel, which covers the first terabyte,
/// and the low half of that range is not named by any other mapping.
///
/// The function runs after the tables of the kernel are active and before
/// any space of a process is created. Calling it twice does nothing.
pub fn prepareBouncePages(allocate: *const fn (limit: u64) ?u64) Error!void {
    if (bounce_ready) return;

    // The frames have to sit below the image of the kernel, so the limit
    // has to be known; without it every candidate frame would collide with
    // a page that the tables of the kernel already map by identity.
    const limit = kernel_lowest_address orelse return error.RangeTooLarge;

    var index: usize = 0;
    while (index < bounce_page_count) : (index += 1) {
        const frame = allocate(limit) orelse return error.OutOfMemory;
        // A frame at or above the image would collide with a page that the
        // tables of the kernel already map by identity, and the collision
        // would give two virtual addresses to one frame — or worse, hide a
        // page of the kernel behind a bounce page.
        if (frame >= limit or frame % page_size != 0) {
            return error.RangeTooLarge;
        }
        try mapKernelIdentityPage(frame);
        bounce_frames[index] = frame;
    }

    bounce_used = 0;
    bounce_ready = true;
}

/// Whether the bounce pages are usable.
pub fn bouncePagesReady() bool {
    return bounce_ready;
}

/// A borrowed view over one page of the window of a process.
///
/// While the view exists, the entry of the window of the space points at a
/// bounce page instead of the frame of the process: the process must not be
/// scheduled during that time, which is guaranteed because the views are
/// only taken from the kernel with the scheduler stopped, inside a system
/// call or inside the boot sequence. The view restores the original entry
/// when it is released, and releasing it more than once does nothing.
pub const PageWindow = struct {
    /// The entry that was restored, or null when the window is empty.
    slot: ?*u64 = null,
    /// The value that the entry held before the borrow.
    saved: u64 = 0,
    /// The bounce page that the entry points at while the view exists.
    frame: u64 = 0,

    /// True when the view still holds the entry.
    pub fn active(self: *const PageWindow) bool {
        return self.slot != null;
    }
};

/// Borrows one page of the window of a space through a bounce page.
///
/// Returns null when the bounce pages were not prepared, when none is
/// free, or when the virtual address is not the address of a page of the
/// window of the space.
pub fn borrowPage(space: *const AddressSpace, virtual: u64) ?PageWindow {
    if (!bounce_ready) return null;
    if (virtual % page_size != 0) return null;
    if (virtual < user_window_base or virtual >= user_window_base + user_window_size) return null;
    if (bounce_used >= bounce_page_count) return null;

    // Only a page that the space actually owns can be borrowed: borrowing
    // an unmapped page would hand out a bounce page for memory that no
    // process owns, and the copy would read zeros and call them data.
    const level1_index = (virtual >> 12) & 511;
    const entry = &space.level1.entries[level1_index];
    if (entry.* & Flags.present == 0) return null;
    if (entry.* & Flags.user == 0) return null;

    const frame = bounce_frames[bounce_used];
    bounce_used += 1;

    const window = PageWindow{
        .slot = entry,
        .saved = entry.*,
        .frame = frame,
    };

    // The bounce page replaces the frame of the process in the entry of
    // the window. The bit of the user mode stays set: the entry keeps the
    // shape of a page of the user, and the processor of the kernel never
    // checks the bit on its own accesses.
    entry.* = frame | Flags.present | Flags.writable | Flags.user;

    return window;
}

/// Gives back a borrowed page and restores the entry of the window.
pub fn releasePage(window: *PageWindow) void {
    const slot = window.slot orelse return;
    slot.* = window.saved;
    window.slot = null;
    if (bounce_used > 0) bounce_used -= 1;
}
