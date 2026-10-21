// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

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

/// Builds a segment selector.
///
/// The encoding of a selector is not a plain index:
///
/// ```text
/// bits 0-12  offset of the descriptor in the table, in bytes
/// bit  3     table indicator, 0 for the global table and 1 for the local one
/// bits 4-5   requested privilege level
/// ```
///
/// The table indicator overlaps the offset field, therefore the selector is
/// assembled and not described by a packed structure.
pub fn makeSelector(byte_offset: u13, table_indicator: u1, rpl: u2) u16 {
    return @as(u16, byte_offset) | (@as(u16, table_indicator) << 3) | (@as(u16, rpl) << 4);
}

/// The selectors used by the kernel.
pub const selectors = struct {
    /// Ring 0 code segment, at offset 8 of the table.
    const kernel_code: u16 = makeSelector(8, 0, 0);
    /// Ring 0 data segment, at offset 16 of the table.
    const kernel_data: u16 = makeSelector(16, 0, 0);
    /// Ring 3 code segment, at offset 24 of the table.
    const user_code: u16 = makeSelector(24, 0, 3);
    /// Ring 3 data segment, at offset 32 of the table.
    const user_data: u16 = makeSelector(32, 0, 3);
    /// Task state segment, at offset 40 of the table.
    const task: u16 = makeSelector(40, 0, 0);
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

/// The 64 bit task state segment.
///
/// The layout is the one of the architecture: the stacks of the privilege
/// levels, the seven interrupt stack table entries and the offset of the I/O
/// permission bitmap. In long mode the offset of the bitmap is a 32 bit
/// field at the end of the structure, the 16 bit field of the 32 bit layout
/// is reserved.
pub const TaskStateSegment = extern struct {
    reserved0: u32 = 0,
    reserved1: u32 = 0,
    /// Stack used when an interrupt arrives from ring 3.
    rsp0: u64 = 0,
    /// Stack used when an interrupt arrives from ring 1.
    rsp1: u64 = 0,
    /// Stack used when an interrupt arrives from ring 2.
    rsp2: u64 = 0,
    reserved2: u64 = 0,
    /// Stack used by the double fault handler.
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved3: u64 = 0,
    reserved4: u16 = 0,
    /// Offset of the I/O permission bitmap in the 32 bit layout.
    iomap_base_16: u16 = 0,
    /// Offset of the I/O permission bitmap in the 64 bit layout. The value
    /// marks the absence of the bitmap, the kernel does not use the
    /// privileged instructions that would need it.
    iomap_base: u32 = 0xFFFF,
};

/// Size of the task state segment structure.
pub const tss_size = @sizeOf(TaskStateSegment);

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
    const base_mid: u32 = @truncate(base >> 16);
    const base_high: u32 = @truncate(base >> 24);

    return .{
        .{
            .low = (@as(u32, limit) & 0xFFFF) | (base_low << 16),
            .high = base_mid | (@as(u32, task_type) << 8) | (@as(u32, @truncate((@as(u64, limit) >> 16) & 0xF)) << 16) | (base_high << 24),
        },
        .{ .low = 0, .high = 0 },
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

    const task = taskSegment(@intFromPtr(&tss), @intCast(tss_size));
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
extern fn voryn_load_gdt(pointer: *const align(8) GdtPointer) callconv(.c) void;

/// Stores the global descriptor table into the given structure.
extern fn voryn_store_gdt(pointer: *align(8) GdtPointer) callconv(.c) void;
