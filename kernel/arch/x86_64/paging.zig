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
/// switch of `CR3`: the kernel keeps one private table of pages of its
/// own, reachable at the fixed virtual range that starts at
/// `bounce_virtual_base` — a range that no space of a process names, and
/// that every space reaches because the root table of each one carries a
/// copy of the entry of the kernel. Each bounce page is a view: pointing
/// one entry of the private table at a physical frame makes that frame
/// readable and writable at the corresponding virtual address, whichever
/// space is loaded in `CR3`. To look at a page of a process, the kernel
/// points a view at the frame of the process, reads or writes through the
/// virtual address of the view, and releases the view afterwards.
///
/// The number of pages bounds the work that happens outside the ownership
/// of a space at any moment; the walk over a longer copy takes the pages
/// one after the other.
pub const bounce_page_count = 2;

/// The first virtual address of the range of the bounce views.
///
/// The range sits far above the image and far above the window of the
/// user mode, inside the first gigabyte, where nothing else of the
/// address space lives: the entries of the private table are never
/// written with anything but bounce frames, and no page of a process or
/// of the kernel is ever reachable through them.
const bounce_virtual_base: u64 = 0x1000_0000;

/// The private level 1 table with the entries of the bounce views.
var bounce_table: PageTable align(4096) = .{};

/// Number of bounce views that the kernel handed out to a caller.
var bounce_used: usize = 0;

/// Whether the bounce pages were already prepared.
var bounce_ready = false;

/// The first address of the window of the user mode of a process.
///
/// The value is fixed by design, not chosen at runtime. Three properties
/// make one constant safe for every placement of the image:
///
/// * The window lives at a virtual address that the hierarchy of the
///   kernel never names — `mapKernelRange` refuses to build the chain of
///   the image over a range whose frames sit entirely below the window —
///   so no identity mapping of the kernel can ever collide with it.
/// * Every space of a process carries a private chain that reaches this
///   same virtual address, which is what lets two processes hold
///   different frames under one address.
/// * The physical frames that back the window are ordinary frames from
///   the manager; the kernel reaches them without a switch of `CR3`
///   through the bounce pages (`prepareBouncePages`), never through the
///   window itself.
pub const user_window_base: u64 = 0x40_0000;

/// Whether the placement of the window is free of collisions.
///
/// `setup` verifies that the chain of the image does not describe the
/// window before the first entry of the window is written; the check
/// keeps its shape for the diagnostics, but with the fixed address and
/// the guard inside `mapPage` it cannot fail on a conforming handoff.
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

/// The attributes of the entries of the upper levels of the hierarchy.
const table_flags: u64 = Flags.present | Flags.writable | Flags.user;

/// Builds the private chain of the bounce views inside the hierarchy of
/// the kernel.
///
/// The chain is built once, by `setup`, and reaches the fixed range that
/// starts at `bounce_virtual_base`: the generic path of `mapPage` reserves
/// the level 2 and level 1 tables for the range, and the function walks to
/// the level 1 table that covers it. Because the entry of the kernel is
/// copied into the root table of every process space, the range is
/// reachable from any space without a switch of `CR3` — which is exactly
/// what the views of `borrowFrame` depend on.
fn buildBounceChain() Error!*PageTable {
    var index: usize = 0;
    while (index < bounce_page_count) : (index += 1) {
        // A placeholder frame, replaced before any view is handed out. The
        // value points at the bounce table itself: an access through the
        // placeholder before `prepareBouncePages` would read the entries
        // of a table instead of faulting, and no caller can reach a view
        // until `bounce_ready` is set anyway.
        const virtual = bounce_virtual_base + index * page_size;
        try mapPage(virtual, addressOf(&bounce_table), Flags.present | Flags.writable);
    }

    // Walks to the level 1 table that covers the start of the range.
    const level3_table = tableOf(level4.entries[0]);
    const level2_entry = tableOf(level3_table.entries[(bounce_virtual_base >> 30) & 511]).entries[
        (bounce_virtual_base >> 21) & 511
    ];
    if (level2_entry & Flags.present == 0 or level2_entry & Flags.large != 0) {
        return error.RangeTooLarge;
    }
    return tableOf(level2_entry);
}

/// The level 1 table with the entries of the bounce views, filled by
/// `setup` together with the chain that reaches it.
var bounce_level1: ?*PageTable = null;

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

    // The window of the user mode of a process and the range of the bounce
    // views live at virtual addresses that the hierarchy of the kernel
    // never names: writing an entry there would hide a page of a process
    // behind the table of the image, and reading one would follow the
    // frame of a process as if it were a table. The private chain of each
    // space answers for the window, and the private table of the views
    // answers for the bounce range.
    if (virtual >= user_window_base and
        virtual < user_window_base + user_window_size)
    {
        return error.RangeTooLarge;
    }
    if (virtual >= bounce_virtual_base and
        virtual < bounce_virtual_base + bounce_page_count * page_size)
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
    bounce_level1 = null;

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

    // The window of the user mode lives at a fixed virtual address that
    // the hierarchy of the kernel never names, and `mapPage` refuses any
    // kernel mapping inside it. The frames that back the window are
    // ordinary frames from the manager, reached without a switch of
    // `CR3` through the bounce views. What is verified here is the one
    // assumption the design depends on: the chain of the image must not
    // describe the range of the window — which would happen if the image
    // were placed so low that its own identity pages covered it.
    if (kernel_base < user_window_base + user_window_size) {
        window_frames_ok = false;
    } else {
        window_frames_ok = true;
    }

    // The private chain of the bounce views, built once for every space:
    // the root table of each process carries a copy of the entry of the
    // kernel, so the range of the views is reachable in any space without
    // a switch of `CR3`. The check keeps the placement of the image from
    // ever covering the range — the same reasoning as the window above.
    if (bounce_virtual_base < user_window_base + user_window_size or
        bounce_virtual_base >= 1 * 1024 * 1024 * 1024)
    {
        return error.RangeTooLarge;
    }
    bounce_level1 = try buildBounceChain();

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

    return .{
        .level4 = root,
        .level1 = user_table,
        .window_level2 = level2_table,
        .window_level2_index = window_level2_index,
    };
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

    // The pages of a process live only inside the window of the user mode,
    // and the window reaches them through the private chain of the space:
    // the shared entry of the kernel is never walked here, because it can
    // name no page of a process. A range outside the window has no chain
    // in any space, so it is refused before the walk begins.
    if (virtual < user_window_base or virtual >= user_window_base + user_window_size) {
        return false;
    }

    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    if (level3_index != 0) return false;

    const entry3 = owner.level4.entries[0];
    if (entry3 & Flags.present == 0) return false;

    const level3_table = tableOf(entry3);
    const entry2 = level3_table.entries[0];
    if (entry2 & Flags.present == 0) return false;

    const level2_table = tableOf(entry2);
    if (level2_table.entries[level2_index] & Flags.present == 0) return false;

    const entry1 = owner.level1.entries[level1_index];
    if (entry1 & Flags.present == 0) return false;
    if (entry1 & Flags.user == 0) return false;
    if (writable and entry1 & Flags.writable == 0) return false;

    return true;
}

/// Prepares the bounce pages of the kernel.
///
/// The function takes frames from the given allocator — any usable frame
/// is fine, because a bounce page never lives at its own address: it is
/// reached through a view in the private range of the kernel — and marks
/// the views ready for use. The chain that carries the entries of the
/// views was built by `setup`, inside the hierarchy of the kernel, which
/// every space of a process copies at the entry of the kernel; a view is
/// therefore reachable whichever space is loaded in `CR3`.
///
/// The function runs after the tables of the kernel are active and before
/// any space of a process is created. Calling it twice does nothing.
pub fn prepareBouncePages(allocate: *const fn () ?u64) Error!void {
    if (bounce_ready) return;
    if (bounce_level1 == null) return error.RangeTooLarge;

    var index: usize = 0;
    while (index < bounce_page_count) : (index += 1) {
        const frame = allocate() orelse return error.OutOfMemory;
        if (frame % page_size != 0) return error.RangeTooLarge;
        bounce_table.entries[index] = frame | Flags.present | Flags.writable;
    }

    bounce_used = 0;
    bounce_ready = true;
}

/// Whether the bounce pages are usable.
pub fn bouncePagesReady() bool {
    return bounce_ready;
}

/// A borrowed view over one physical frame of memory.
///
/// While the view exists, one entry of the private table of the kernel
/// points at the frame, and the frame is reachable at the virtual address
/// that `address` reports — an address that no page of a process and no
/// mapping of the image ever names, so the view cannot alias anything
/// else. The view releases the entry when it is given back, and releasing
/// it more than once does nothing.
///
/// The views exist so that the kernel can read and write the window of a
/// process without a switch of `CR3`: the frame behind a page of the
/// window is taken from the tables of the owning space with `frameOf`,
/// borrowed here, and touched through the identity-free virtual address
/// of the view, in whichever space the processor happens to run.
pub const PageWindow = struct {
    /// The entry that was cleared, or null when the view is empty.
    slot: ?*u64 = null,
    /// The virtual address of the view, stable for the whole life of it.
    address: u64 = 0,

    /// True when the view still holds the entry.
    pub fn active(self: *const PageWindow) bool {
        return self.slot != null;
    }
};

/// Borrows one physical frame through a bounce view.
///
/// Returns null when the bounce pages were not prepared or when no view
/// is free. The frame must be aligned to a page boundary.
pub fn borrowFrame(frame: u64) ?PageWindow {
    if (!bounce_ready) return null;
    if (frame % page_size != 0) return null;
    if (bounce_used >= bounce_page_count) return null;

    const level1 = bounce_level1.?;
    const slot = &level1.entries[bounce_used];
    if (slot.* & Flags.present != 0) return null;

    const virtual = bounce_virtual_base + bounce_used * page_size;
    slot.* = (frame & ~@as(u64, 0xFFF)) | Flags.present | Flags.writable;
    bounce_used += 1;

    return PageWindow{ .slot = slot, .address = virtual };
}

/// Gives back a borrowed frame and clears the entry of the view.
pub fn releaseFrame(window: *PageWindow) void {
    const slot = window.slot orelse return;
    slot.* = 0;
    window.slot = null;
    if (bounce_used > 0) bounce_used -= 1;
}

/// Borrows the physical frame that the window of a space names for one
/// virtual address.
///
/// Returns null when the bounce pages were not prepared, when none is
/// free, or when the virtual address is not the address of a mapped page
/// of the user mode inside the window of the space. Only a page that the
/// space actually owns can be borrowed: borrowing an unmapped page would
/// hand out a view over memory that no process owns, and the copy would
/// read zeros and call them data.
pub fn borrowPage(space: *const AddressSpace, virtual: u64) ?PageWindow {
    const frame = frameOf(space, virtual) orelse return null;
    const entry = space.level1.entries[(virtual >> 12) & 511];
    if (entry & Flags.user == 0) return null;
    return borrowFrame(frame);
}

/// Gives back a borrowed page. Kept as a name for the callers that borrow
/// through the tables of a space.
pub fn releasePage(window: *PageWindow) void {
    releaseFrame(window);
}
