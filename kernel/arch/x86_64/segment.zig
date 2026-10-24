//************************************************************************//
//  segment.zig                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! x86_64 segment descriptors: the Global Descriptor Table and the Task
//! State Segment.
//!
//! The firmware leaves its own GDT active when it hands control to the
//! kernel. The kernel installs its own table so that it controls the
//! privilege levels and the stack that is used when an interrupt arrives
//! from a less privileged context.
//!
//! Layout of the table:
//!
//! ```text
//! 0x00  null
//! 0x08  kernel code   (ring 0)
//! 0x10  kernel data   (ring 0)
//! 0x18  user code     (ring 3)
//! 0x20  user data     (ring 3)
//! 0x28  task state segment (16 bytes)
//! ```

const std = @import("std");
const voryn = @import("voryn_shared");

const testing = std.testing;

/// Builds a segment selector.
///
/// The encoding of a selector is not a plain index:
///
/// ```text
/// bits 0-1   requested privilege level
/// bit  2     table indicator, 0 for the global table and 1 for the local one
/// bits 3-15  offset of the descriptor in the table, in bytes
/// ```
///
/// The offset field holds the address of the descriptor and not its index,
/// therefore the selector of the descriptor at the offset 24 is the value
/// 24, and not the value 3. The table indicator and the privilege level
/// occupy the two lowest fields, and not the fields above the offset.
///
/// The selector is assembled and not described by a packed structure,
/// because the fields of the architecture are not contiguous in the way a
/// packed structure would require.
pub fn makeSelector(byte_offset: u13, table_indicator: u1, rpl: u2) u16 {
    return @as(u16, byte_offset) |
        (@as(u16, table_indicator) << 2) |
        (@as(u16, rpl) & 0x3);
}

/// The selectors used by the kernel.
pub const selectors = struct {
    /// Ring 0 code segment, at offset 8 of the table.
    pub const kernel_code: u16 = makeSelector(8, 0, 0);
    /// Ring 0 data segment, at offset 16 of the table.
    pub const kernel_data: u16 = makeSelector(16, 0, 0);
    /// Ring 3 code segment, at offset 24 of the table.
    pub const user_code: u16 = makeSelector(24, 0, 3);
    /// Ring 3 data segment, at offset 32 of the table.
    pub const user_data: u16 = makeSelector(32, 0, 3);
    /// Task state segment, at offset 40 of the table.
    pub const task: u16 = makeSelector(40, 0, 0);
};

/// A GDT entry, eight bytes wide.
///
/// The first four bytes hold the limit and the low part of the base
/// address, the last four bytes hold the access byte, the flags and the high
/// part of the base address.
const Entry = extern struct {
    low: u32 = 0,
    high: u32 = 0,
};

/// The pointer that is loaded into the `GDTR` register.
const GdtPointer = packed struct {
    limit: u16,
    base: u64,
};

// The layout of the descriptor and of the pointer is part of the contract
// with the processor: the check below makes sure that the layout does not
// drift.
comptime {
    if (@sizeOf(Entry) != 8) @compileError("the descriptor of the table is not eight bytes wide");
    if (@offsetOf(GdtPointer, "base") != 2) @compileError("the base of the table is not at the offset 2");
    if (@bitSizeOf(GdtPointer) != 80) @compileError("the pointer of the table is not ten bytes wide");
}

/// The 64 bit task state segment.
///
/// The layout is the one of the architecture in the long mode, and it is not
/// the layout of the protected mode: the structure of the long mode has no
/// field for the selector of the stack segment, because the processor does
/// not use it there. The offsets are therefore:
///
/// ```text
/// 0x00  4   reserved
/// 0x04  8   RSP0, the stack of the interrupts that arrive from ring 3
/// 0x0C  8   RSP1, the stack of the interrupts that arrive from ring 1
/// 0x14  8   RSP2, the stack of the interrupts that arrive from ring 2
/// 0x1C  8   reserved
/// 0x24  8   IST1, the stack of the double fault
/// 0x2C  8   IST2
/// 0x34  8   IST3
/// 0x3C  8   IST4
/// 0x44  8   IST5
/// 0x4C  8   IST6
/// 0x54  8   IST7
/// 0x5C  8   reserved
/// 0x64  4   reserved
/// 0x66  2   offset of the I/O permission bitmap
/// ```
///
/// The structure has 104 bytes and the limit of the segment is its last
/// byte, 103.
///
/// The structure is packed because the fields of the long mode are not
/// aligned with the natural alignment of their type: the stack of ring 3 is
/// at the offset 4 and not at the offset 8, and the compiler would insert
/// four bytes of padding between the first word and the first stack.
pub const TaskStateSegment = packed struct {
    reserved0: u32 = 0,
    /// Stack used when an interrupt arrives from ring 3.
    rsp0: u64 = 0,
    /// Stack used when an interrupt arrives from ring 1.
    rsp1: u64 = 0,
    /// Stack used when an interrupt arrives from ring 2.
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    /// Stack used by the double fault handler.
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u32 = 0,
    reserved3: u32 = 0,
    reserved4: u16 = 0,
    /// Offset of the I/O permission bitmap in the 64 bit layout. The value
    /// marks the absence of the bitmap, the kernel does not use the
    /// privileged instructions that would need it.
    iomap_base: u16 = 0xFFFF,
};

// The offsets of the structure are part of the contract with the processor:
// the check below makes sure that the layout does not drift.
comptime {
    if (@offsetOf(TaskStateSegment, "rsp0") != 0x04) @compileError("the stack of ring 3 is not at the offset 4");
    if (@offsetOf(TaskStateSegment, "rsp1") != 0x0C) @compileError("the stack of ring 1 is not at the offset 12");
    if (@offsetOf(TaskStateSegment, "rsp2") != 0x14) @compileError("the stack of ring 2 is not at the offset 20");
    if (@offsetOf(TaskStateSegment, "ist1") != 0x24) @compileError("the stack of the double fault is not at the offset 36");
    if (@offsetOf(TaskStateSegment, "ist7") != 0x54) @compileError("the last stack of the table is not at the offset 84");
    if (@offsetOf(TaskStateSegment, "iomap_base") != 0x66) @compileError("the map of the ports is not at the offset 102");
    if (@offsetOf(TaskStateSegment, "iomap_base") + 2 != tss_size) @compileError("the task state segment does not have the size of the architecture");
}

/// The size of the structure of the long mode.
///
/// The compiler adds eight bytes of padding at the end of the structure,
/// because the alignment of the structure is sixteen bytes. The processor
/// only reads the first 104 bytes, and the limit of the segment is the
/// offset of the last one.
pub const tss_size = 104;

/// Number of entries of the table, the task state segment counts as two.
const entry_count = 7;

/// Type of a present and available 64 bit task state segment.
const task_type: u32 = 0x89;

/// The table itself, aligned as the architecture requires.
var table: [entry_count]Entry align(16) = @splat(.{ .low = 0, .high = 0 });

/// The pointer loaded into the `GDTR` register.
var table_pointer: GdtPointer align(8) = .{ .limit = 0, .base = 0 };

/// The task state segment of the kernel.
pub var tss: TaskStateSegment align(16) = .{};

/// Stack used by the double fault handler, the only interrupt that may
/// arrive while another one is being handled.
var double_fault_stack: [16 * 1024]u8 align(16) = undefined;

/// Builds a flat code segment descriptor.
fn codeSegment(access: u8, flags: u8) Entry {
    return .{
        .low = 0x0000_FFFF,
        .high = (@as(u32, access) << 8) | (0xF << 16) | (@as(u32, flags) << 20),
    };
}

/// Builds a flat data segment descriptor.
fn dataSegment(access: u8, flags: u8) Entry {
    return codeSegment(access, flags);
}

/// Builds the sixteen byte descriptor of a task state segment.
///
/// The type byte of a system descriptor carries the present bit in its
/// highest position, so a present and available 64 bit task state segment has
/// the type `0x89` and not `0x09`.
fn taskSegment(base: u64, limit: u16) [2]Entry {
    const base_low: u32 = @truncate(base);
    const base_mid: u32 = @as(u32, @truncate(base >> 16)) & 0xFF;
    const base_high: u32 = @as(u32, @truncate(base >> 24)) & 0xFF;

    return .{
        .{
            .low = (@as(u32, limit) & 0xFFFF) | (base_low << 16),
            .high = base_mid | (@as(u32, task_type) << 8) | (@as(u32, @truncate((@as(u64, limit) >> 16) & 0xF)) << 16) | (base_high << 24),
        },
        // A 64-bit TSS descriptor stores base[63:32] in the second entry.
        // Without this half, LTR faults with #GP(selector) when the TSS is
        // located above 4 GiB; keep the descriptor correct for all bases.
        .{ .low = @truncate(base >> 32), .high = 0 },
    };
}

/// Installs the table and the task state segment.
///
/// `kernel_stack_top` is the top of the stack the kernel uses, it becomes
/// the stack of ring 0 when an interrupt arrives from user mode.
pub fn install(kernel_stack_top: u64) void {
    // The null descriptor, the code and data segments of both privilege
    // levels and the task state segment.
    table[0] = .{ .low = 0, .high = 0 };
    table[1] = codeSegment(0x9A, 0x0A); // ring 0 code, long mode
    table[2] = dataSegment(0x92, 0x0C); // ring 0 data
    table[3] = codeSegment(0xFA, 0x0A); // ring 3 code, long mode
    table[4] = dataSegment(0xF2, 0x0C); // ring 3 data

    tss.rsp0 = kernel_stack_top;
    tss.ist1 = @intFromPtr(&double_fault_stack) + double_fault_stack.len;

    // The limit of the segment is the offset of its last byte.
    const task = taskSegment(@intFromPtr(&tss), @intCast(tss_size - 1));
    table[5] = task[0];
    table[6] = task[1];

    table_pointer = .{
        .limit = @intCast(entry_count * @sizeOf(Entry) - 1),
        .base = @intFromPtr(&table),
    };

    // The instruction has no register form, the accessors are in assembly.
    voryn_load_gdt(&table_pointer);

    // The data segments are reloaded first, the code segment follows with a
    // far jump.
    voryn_gdt_load_data(selectors.kernel_data);
    voryn_gdt_load_code(selectors.kernel_code);
}

/// Loads the task state segment into the `TR` register.
///
/// The load is done after the interrupt table, so that a failure of the
/// instruction is reported by the handler of the kernel.
pub fn loadTaskState() void {
    voryn_load_tss(selectors.task);
}

/// Reads back the `GDTR` register, used to verify the installation.
pub fn readTablePointer() GdtPointer {
    var pointer: GdtPointer = undefined;
    voryn_store_gdt(&pointer);
    return pointer;
}

/// Verifies that the table that is active is the one the kernel installed.
pub fn verify() bool {
    const pointer = readTablePointer();
    return pointer.base == @intFromPtr(&table) and
        pointer.limit == entry_count * @sizeOf(Entry) - 1;
}

/// Reloads the data segment registers with the selector of the kernel.
extern fn voryn_gdt_load_data(data_selector: u16) callconv(.c) void;

/// Reloads the code segment with the selector of the kernel.
extern fn voryn_gdt_load_code(code_selector: u16) callconv(.c) void;

/// Loads the task state segment with the given selector.
extern fn voryn_load_tss(selector: u16) callconv(.c) void;

/// Loads the global descriptor table from the given structure.
extern fn voryn_load_gdt(pointer: *align(8) const GdtPointer) callconv(.c) void;

/// Stores the global descriptor table into the given structure.
extern fn voryn_store_gdt(pointer: *align(8) GdtPointer) callconv(.c) void;

test "the selector carries the privilege level in the two lowest fields" {
    // The descriptor of the third level of privilege is at the offset 24 of
    // the table, and the selector of the third level has the value 3 in the
    // field of the privilege level.
    const selector = makeSelector(24, 0, 3);

    try testing.expectEqual(@as(u16, 0x1b), selector);
    try testing.expectEqual(@as(u16, 3), selector & 0x3);
    try testing.expectEqual(@as(u16, 0), (selector >> 2) & 0x1);
    try testing.expectEqual(@as(u16, 3), selector >> 3);
}

test "the selector of the local table is marked" {
    const selector = makeSelector(24, 1, 3);

    try testing.expectEqual(@as(u16, 1), (selector >> 2) & 0x1);
    try testing.expectEqual(@as(u16, 3), selector & 0x3);
}

test "the selectors of the table are the expected ones" {
    // The table has the null descriptor, the code and the data of the two
    // levels of privilege, and the task state segment.
    try testing.expectEqual(@as(u16, 0x08), selectors.kernel_code);
    try testing.expectEqual(@as(u16, 0x10), selectors.kernel_data);
    try testing.expectEqual(@as(u16, 0x1b), selectors.user_code);
    try testing.expectEqual(@as(u16, 0x23), selectors.user_data);
    try testing.expectEqual(@as(u16, 0x28), selectors.task);
}

test "the task state segment has the layout of the long mode" {
    // The layout of the long mode is not the layout of the protected mode:
    // the structure has no field for the selector of the stack segment, and
    // the stack of ring 3 is therefore at the offset 4.
    try testing.expectEqual(@as(usize, 0x04), @offsetOf(TaskStateSegment, "rsp0"));
    try testing.expectEqual(@as(usize, 0x0C), @offsetOf(TaskStateSegment, "rsp1"));
    try testing.expectEqual(@as(usize, 0x14), @offsetOf(TaskStateSegment, "rsp2"));
    try testing.expectEqual(@as(usize, 0x24), @offsetOf(TaskStateSegment, "ist1"));
    try testing.expectEqual(@as(usize, 0x54), @offsetOf(TaskStateSegment, "ist7"));
    try testing.expectEqual(@as(usize, 0x66), @offsetOf(TaskStateSegment, "iomap_base"));

    // The limit of the segment is the offset of its last byte, and the
    // processor requires the limit to be at least 103, which is the size of
    // the structure minus one.
    try testing.expectEqual(@as(usize, 104), tss_size);
    try testing.expect(tss_size - 1 >= 103);
}

test "TSS descriptor stores the upper half of the TSS base" {
    const base: u64 = 0x1234_5678_9abc_def0;
    const entries = taskSegment(base, 103);
    try testing.expectEqual(@as(u32, @truncate(base >> 32)), entries[1].low);
    try testing.expectEqual(@as(u32, 0), entries[1].high);
    try testing.expectEqual(@as(u32, 103), entries[0].low & 0xffff);
    try testing.expectEqual(@as(u32, 0x89), (entries[0].high >> 8) & 0xff);
    try testing.expectEqual(@as(u32, 0x9a), entries[0].low >> 16);
    try testing.expectEqual(@as(u32, 0xbc), entries[0].high & 0xff);
    try testing.expectEqual(@as(u32, 0xde), entries[0].high >> 24);
}
