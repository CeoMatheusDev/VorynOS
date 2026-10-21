// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! The interrupt descriptor table and the exception handler of the kernel.
//!
//! The table has 256 entries. The first 32 are the exceptions of the
//! processor, the next 16 are the hardware interrupts of the first two
//! interrupt controllers. The remaining entries are reserved and point at a
//! stub that reports the unexpected vector.
//!
//! The layout of the frame that the stubs build is described by
//! `Registers`. The processor pushes the error code of the exceptions that
//! have one below the word that the stub pushes, therefore the handler reads
//! the error code from the address of the frame, not from the frame itself.

const std = @import("std");
const voryn = @import("voryn_shared");

const serial = voryn.serial;
const port = voryn.port;

/// Number of entries of the table.
pub const entry_count = 256;

/// The number of exceptions of the processor.
pub const exception_count = 32;

/// A gate descriptor of the table, sixteen bytes wide.
///
/// The layout follows the architecture exactly:
///
/// ```text
/// 0-1   offset of the handler, low part
/// 2-3   selector of the code segment
/// 4     interrupt stack table index in the low three bits
/// 5     gate type, privilege level and present bit
/// 6-7   offset of the handler, middle part
/// 8-11  offset of the handler, high part
/// 12-15 reserved
/// ```
pub const Gate = extern struct {
    offset_low: u16 = 0,
    selector: u16 = 0,
    /// The stack table index in the low three bits, the rest is reserved.
    ist: u8 = 0,
    /// The gate type, the privilege level and the present bit.
    type_attributes: u8 = 0,
    offset_middle: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,
};

/// The pointer that is loaded into the `IDTR` register.
const IdtPointer = packed struct {
    limit: u16,
    base: u64,
};

/// Type of an interrupt gate: present, ring 0, interrupt gate.
const gate_type: u8 = 0x8E;

/// Type of an interrupt gate that the user mode may call: present, ring 3.
const user_gate_type: u8 = 0xEE;

/// The vector of the system calls.
pub const syscall_vector: u8 = 0x80;

/// The register frame that the stubs build.
pub const Registers = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    r11: u64 = 0,
    r10: u64 = 0,
    r9: u64 = 0,
    r8: u64 = 0,
    rbx: u64 = 0,
    rbp: u64 = 0,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rdx: u64 = 0,
    rcx: u64 = 0,
    rax: u64 = 0,
    /// The vector that caused the exception.
    vector: u64 = 0,
};

/// The table itself.
var table: [entry_count]Gate align(16) = @splat(.{});

/// The pointer loaded into the `IDTR` register.
var table_pointer: IdtPointer align(8) = .{ .limit = 0, .base = 0 };

/// The selector of the kernel code segment, used by the gates.
const kernel_code_selector: u16 = 0x08;

/// Exceptions that push an error code.
///
/// The table is the one of the long mode: the exception of stack segment is
/// the vector 13 and the lack of page is the vector 14, the opposite of the
/// table of the protected mode.
pub fn hasErrorCode(vector: u64) bool {
    return switch (vector) {
        8, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

/// Name of a vector, for the diagnostic output.
pub fn vectorName(vector: u64) []const u8 {
    return switch (vector) {
        0 => "divide error",
        1 => "debug",
        2 => "non maskable interrupt",
        3 => "breakpoint",
        4 => "overflow",
        5 => "bound range exceeded",
        6 => "invalid opcode",
        7 => "device not available",
        8 => "double fault",
        9 => "reserved",
        10 => "reserved",
        11 => "segment not present",
        12 => "general protection fault",
        13 => "stack fault",
        14 => "page fault",
        15 => "reserved",
        16 => "x87 floating point",
        17 => "alignment check",
        18 => "invalid TSS",
        19 => "segment not present",
        20 => "virtualization",
        21 => "control protection",
        22 => "maskable interrupt",
        23 => "hypervisor injection",
        24 => "VMM communication",
        25 => "security exception",
        26 => "reserved",
        27 => "reserved",
        28 => "hypervisor injection",
        29 => "VMM communication",
        30 => "security exception",
        31 => "reserved",
        32...47 => "hardware interrupt",
        else => "unexpected vector",
    };
}

/// Installs the table and loads it into the processor.
pub fn install() void {
    // The exceptions of the processor.
    for (0..exception_count) |vector| {
        setGate(vector, stubFor(vector));
    }

    // The hardware interrupts.
    for (0..hardware_interrupt_count) |index| {
        setGate(first_hardware_vector + @as(usize, index), interruptStubFor(index));
    }

    // The vectors that are not handled point at a stub that reports them.
    const unexpected = stubFor(255);
    for (exception_count + hardware_interrupt_count..entry_count) |vector| {
        if (vector == syscall_vector) continue;
        setGate(vector, unexpected);
    }

    // The system call, the only gate that the user mode may call. It is
    // installed after the reserved vectors, because its vector is part of
    // them.
    table[syscall_vector] = .{
        .offset_low = @truncate(@intFromPtr(&voryn_syscall_entry)),
        .selector = kernel_code_selector,
        .ist = 0,
        .type_attributes = user_gate_type,
        .offset_middle = @truncate(@intFromPtr(&voryn_syscall_entry) >> 16),
        .offset_high = @truncate(@intFromPtr(&voryn_syscall_entry) >> 32),
    };

    table_pointer = .{
        .limit = @intCast(entry_count * @sizeOf(Gate) - 1),
        .base = @intFromPtr(&table),
    };

    voryn_load_idt(&table_pointer);
}

/// Writes the gate of a vector.
fn setGate(vector: usize, address: u64) void {
    table[vector] = .{
        .offset_low = @truncate(address),
        .selector = kernel_code_selector,
        .ist = 0,
        .type_attributes = gate_type,
        .offset_middle = @truncate(address >> 16),
        .offset_high = @truncate(address >> 32),
    };
}

/// Returns the address of the entry point of a vector.
fn stubFor(vector: usize) u64 {
    return switch (vector) {
        0 => @intFromPtr(&voryn_exception_0),
        1 => @intFromPtr(&voryn_exception_1),
        2 => @intFromPtr(&voryn_exception_2),
        3 => @intFromPtr(&voryn_exception_3),
        4 => @intFromPtr(&voryn_exception_4),
        5 => @intFromPtr(&voryn_exception_5),
        6 => @intFromPtr(&voryn_exception_6),
        7 => @intFromPtr(&voryn_exception_7),
        8 => @intFromPtr(&voryn_exception_8),
        9 => @intFromPtr(&voryn_exception_9),
        10 => @intFromPtr(&voryn_exception_10),
        11 => @intFromPtr(&voryn_exception_11),
        12 => @intFromPtr(&voryn_exception_12),
        13 => @intFromPtr(&voryn_exception_13),
        14 => @intFromPtr(&voryn_exception_14),
        15 => @intFromPtr(&voryn_exception_15),
        16 => @intFromPtr(&voryn_exception_16),
        17 => @intFromPtr(&voryn_exception_17),
        18 => @intFromPtr(&voryn_exception_18),
        19 => @intFromPtr(&voryn_exception_19),
        20 => @intFromPtr(&voryn_exception_20),
        21 => @intFromPtr(&voryn_exception_21),
        22 => @intFromPtr(&voryn_exception_22),
        23 => @intFromPtr(&voryn_exception_23),
        24 => @intFromPtr(&voryn_exception_24),
        25 => @intFromPtr(&voryn_exception_25),
        26 => @intFromPtr(&voryn_exception_26),
        27 => @intFromPtr(&voryn_exception_27),
        28 => @intFromPtr(&voryn_exception_28),
        29 => @intFromPtr(&voryn_exception_29),
        30 => @intFromPtr(&voryn_exception_30),
        31 => @intFromPtr(&voryn_exception_31),
        else => @intFromPtr(&voryn_exception_unexpected),
    };
}

/// The first vector of the hardware interrupts.
pub const first_hardware_vector: u8 = 32;

/// The number of hardware interrupts.
pub const hardware_interrupt_count: u8 = 16;

/// Returns the address of the entry point of a hardware interrupt.
fn interruptStubFor(index: usize) u64 {
    return switch (index) {
        0 => @intFromPtr(&voryn_interrupt_32),
        1 => @intFromPtr(&voryn_interrupt_33),
        2 => @intFromPtr(&voryn_interrupt_34),
        3 => @intFromPtr(&voryn_interrupt_35),
        4 => @intFromPtr(&voryn_interrupt_36),
        5 => @intFromPtr(&voryn_interrupt_37),
        6 => @intFromPtr(&voryn_interrupt_38),
        7 => @intFromPtr(&voryn_interrupt_39),
        8 => @intFromPtr(&voryn_interrupt_40),
        9 => @intFromPtr(&voryn_interrupt_41),
        10 => @intFromPtr(&voryn_interrupt_42),
        11 => @intFromPtr(&voryn_interrupt_43),
        12 => @intFromPtr(&voryn_interrupt_44),
        13 => @intFromPtr(&voryn_interrupt_45),
        14 => @intFromPtr(&voryn_interrupt_46),
        15 => @intFromPtr(&voryn_interrupt_47),
        else => @intFromPtr(&voryn_exception_unexpected),
    };
}

/// Reads the pointer that is loaded into the `IDTR` register.
pub fn readTablePointer() IdtPointer {
    var pointer: IdtPointer = undefined;
    voryn_store_idt(&pointer);
    return pointer;
}

/// Verifies that the table that is active is the one the kernel installed.
pub fn verify() bool {
    const pointer = readTablePointer();
    return pointer.base == @intFromPtr(&table) and
        pointer.limit == entry_count * @sizeOf(Gate) - 1;
}

/// The frame of the processor that the stub built.
///
/// The stub pushes a word for the error code and the vector, and the
/// processor frame is above them. The order of the addresses is the reverse
/// of the order of the pushes of the processor.
pub const ProcessorFrame = struct {
    /// The error code, zero when the exception does not push one.
    error_code: u64 = 0,
    /// The instruction that was being executed.
    rip: u64 = 0,
    /// The code segment.
    cs: u64 = 0,
    /// The flags.
    rflags: u64 = 0,
    /// The stack pointer.
    rsp: u64 = 0,
    /// The stack segment.
    ss: u64 = 0,
};

/// Reads the frame of the processor from the frame of the registers.
pub fn processorFrame(vector: u64, frame: *const Registers) ProcessorFrame {
    const base = @intFromPtr(frame) + @sizeOf(Registers);

    // The stub pushes a word for the error code, the processor pushes the
    // real one right above it.
    const has_error = hasErrorCode(vector);
    const error_code: u64 = if (has_error) readWord(base + 8) else 0;
    const pointer = base + 8 + (if (has_error) @as(usize, 8) else 0);

    return .{
        .error_code = error_code,
        .rip = readWord(pointer),
        .cs = readWord(pointer + 8),
        .rflags = readWord(pointer + 16),
        .rsp = readWord(pointer + 24),
        .ss = readWord(pointer + 32),
    };
}

/// Handler of the exceptions of the processor.
///
/// The handler prints the state of the processor and stops the kernel: an
/// exception that is not handled explicitly is fatal.
export fn voryn_exception_handler(vector: u64, frame: *const Registers) callconv(.c) void {
    const processor = processorFrame(vector, frame);

    serial.printLine("[VNK] EXCEPTION {d}: {s}", .{ vector, vectorName(vector) });
    serial.printLine("[VNK]   error code: 0x{x}", .{processor.error_code});
    serial.printLine("[VNK]   rip=0x{x} cs=0x{x} rflags=0x{x}", .{
        processor.rip,
        processor.cs,
        processor.rflags,
    });
    serial.printLine("[VNK]   rax=0x{x} rbx=0x{x} rcx=0x{x} rdx=0x{x}", .{
        frame.rax,
        frame.rbx,
        frame.rcx,
        frame.rdx,
    });
    serial.printLine("[VNK]   rsi=0x{x} rdi=0x{x} rsp=0x{x} rbp=0x{x}", .{
        frame.rsi,
        frame.rdi,
        processor.rsp,
        frame.rbp,
    });

    port.haltForever();
}

/// Handler of the system calls.
///
/// The handler runs in the kernel: the processor switched to the stack of the
/// task state segment before it delivered the call.
export fn voryn_syscall_handler(vector: u64, frame: *Registers) callconv(.c) void {
    const processor = processorFrame(vector, frame);

    const number = frame.rax;
    const argument = frame.rdi;

    serial.printLine("[VNK] syscall {d} argument 0x{x} cs=0x{x} ss=0x{x}", .{
        number,
        argument,
        processor.cs,
        processor.ss,
    });

    // The result of the call is returned in the first register.
    frame.rax = 0x42;
}

/// Handler of the hardware interrupts.
///
/// The handler acknowledges the interrupt to the controllers and returns to
/// the interrupted code.
export fn voryn_interrupt_handler(vector: u64, frame: *const Registers) callconv(.c) u64 {
    _ = frame;

    if (vector >= first_hardware_vector and vector < first_hardware_vector + hardware_interrupt_count) {
        const timer = @import("timer.zig");
        if (vector == first_hardware_vector) {
            timer.onTick();

            // The scheduler decides whether another task has to run. The
            // value that is returned tells the entry point of the interrupt
            // to switch.
            const scheduler = @import("../../task/scheduler.zig");
            const must_switch = scheduler.scheduler.tick();
            timer.acknowledge(@intCast(vector));
            return if (must_switch) 1 else 0;
        }

        timer.acknowledge(@intCast(vector));
    }

    return 0;
}

/// Reads a word of the frame.
fn readWord(address: usize) u64 {
    const value: *const u64 = @ptrFromInt(address);
    return value.*;
}

/// Loads the interrupt descriptor table.
extern fn voryn_load_idt(pointer: *const align(8) IdtPointer) callconv(.c) void;

/// Stores the interrupt descriptor table.
extern fn voryn_store_idt(pointer: *align(8) IdtPointer) callconv(.c) void;

// The entry points are declared as variables: the address of a constant of
// the standard library is the address of a copy, and the gates of the table
// need the address of the symbol itself.
extern var voryn_exception_0: u8;
extern var voryn_exception_1: u8;
extern var voryn_exception_2: u8;
extern var voryn_exception_3: u8;
extern var voryn_exception_4: u8;
extern var voryn_exception_5: u8;
extern var voryn_exception_6: u8;
extern var voryn_exception_7: u8;
extern var voryn_exception_8: u8;
extern var voryn_exception_9: u8;
extern var voryn_exception_10: u8;
extern var voryn_exception_11: u8;
extern var voryn_exception_12: u8;
extern var voryn_exception_13: u8;
extern var voryn_exception_14: u8;
extern var voryn_exception_15: u8;
extern var voryn_exception_16: u8;
extern var voryn_exception_17: u8;
extern var voryn_exception_18: u8;
extern var voryn_exception_19: u8;
extern var voryn_exception_20: u8;
extern var voryn_exception_21: u8;
extern var voryn_exception_22: u8;
extern var voryn_exception_23: u8;
extern var voryn_exception_24: u8;
extern var voryn_exception_25: u8;
extern var voryn_exception_26: u8;
extern var voryn_exception_27: u8;
extern var voryn_exception_28: u8;
extern var voryn_exception_29: u8;
extern var voryn_exception_30: u8;
extern var voryn_exception_31: u8;
extern var voryn_exception_unexpected: u8;
extern var voryn_syscall_entry: u8;
extern var voryn_interrupt_32: u8;
extern var voryn_interrupt_33: u8;
extern var voryn_interrupt_34: u8;
extern var voryn_interrupt_35: u8;
extern var voryn_interrupt_36: u8;
extern var voryn_interrupt_37: u8;
extern var voryn_interrupt_38: u8;
extern var voryn_interrupt_39: u8;
extern var voryn_interrupt_40: u8;
extern var voryn_interrupt_41: u8;
extern var voryn_interrupt_42: u8;
extern var voryn_interrupt_43: u8;
extern var voryn_interrupt_44: u8;
extern var voryn_interrupt_45: u8;
extern var voryn_interrupt_46: u8;
extern var voryn_interrupt_47: u8;
