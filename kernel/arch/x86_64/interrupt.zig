//************************************************************************//
//  interrupt.zig                                                         //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

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

const cpu = @import("cpu.zig");
const frame_layout = @import("frame.zig");

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

// The layout of the gate and of the pointer is part of the contract with
// the processor: the check below makes sure that the layout does not drift.
comptime {
    if (@sizeOf(Gate) != 16) @compileError("the gate of the table is not sixteen bytes wide");
    if (@offsetOf(Gate, "offset_low") != 0) @compileError("the low part of the handler is not at the offset 0");
    if (@offsetOf(Gate, "selector") != 2) @compileError("the selector is not at the offset 2");
    if (@offsetOf(Gate, "ist") != 4) @compileError("the index of the stack is not at the offset 4");
    if (@offsetOf(Gate, "type_attributes") != 5) @compileError("the attributes are not at the offset 5");
    if (@offsetOf(Gate, "offset_middle") != 6) @compileError("the middle of the handler is not at the offset 6");
    if (@offsetOf(Gate, "offset_high") != 8) @compileError("the high part of the handler is not at the offset 8");
    if (@offsetOf(Gate, "reserved") != 12) @compileError("the reserved field is not at the offset 12");
    if (@offsetOf(IdtPointer, "base") != 2) @compileError("the base of the table is not at the offset 2");
    if (@bitSizeOf(IdtPointer) != 80) @compileError("the pointer of the table is not ten bytes wide");
}

/// Type of an interrupt gate: present, ring 0, interrupt gate.
const gate_type: u8 = 0x8E;

/// The register frame that the stubs build.
///
/// The frame contract is in `frame.zig`, which is the module that the
/// handler, the switch and the processor return read.
pub const Registers = frame_layout.Registers;

/// The table itself.
var table: [entry_count]Gate align(16) = @splat(.{});

/// The pointer loaded into the `IDTR` register.
var table_pointer: IdtPointer align(8) = .{ .limit = 0, .base = 0 };

/// The selector of the kernel code segment, used by the gates.
const kernel_code_selector: u16 = 0x08;

/// The selector of the kernel data segment.
const kernel_data_selector: u64 = 0x10;

/// The selector of the user code segment.
///
/// The exception that happened with this selector came from a process, and
/// not from the kernel.
const user_code_selector: u64 = 0x1b;

/// The place where a task that was killed waits, in the kernel.
extern var voryn_killed_task_loop: u8;

/// The error code of the last exception that pushed one.
///
/// The stub of an exception with an error code saves the code here before it
/// normalizes the frame, and the handler reads the code from here.
pub extern var voryn_exception_error_code: u64;

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
        10 => "invalid TSS",
        11 => "segment not present",
        12 => "stack segment fault",
        13 => "general protection fault",
        14 => "page fault",
        15 => "reserved",
        16 => "x87 floating point",
        17 => "alignment check",
        18 => "machine check",
        19 => "SIMD floating point",
        20 => "virtualization",
        21 => "control protection",
        22 => "reserved",
        23 => "reserved",
        24 => "reserved",
        25 => "reserved",
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
        setGate(vector, unexpected);
    }

    table_pointer = .{
        .limit = @intCast(entry_count * @sizeOf(Gate) - 1),
        .base = @intFromPtr(&table),
    };

    voryn_load_idt(&table_pointer);
}

/// The vector of the double fault.
const double_fault_vector: usize = 8;

/// Writes the gate of a vector.
///
/// The gate of the double fault uses the stack of the task segment: the
/// double fault is the exception that happens when the stack of the kernel
/// is already broken, and the stack of the task segment is the one that
/// does not depend on it. The other gates use the stack of the kernel of
/// the task, which is the stack that the exception interrupted.
fn setGate(vector: usize, address: u64) void {
    table[vector] = .{
        .offset_low = @truncate(address),
        .selector = kernel_code_selector,
        .ist = if (vector == double_fault_vector) 1 else 0,
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
pub const ProcessorFrame = frame_layout.ProcessorFrame;

/// Handler of the exceptions of the processor.
///
/// The handler prints the state of the processor and stops the kernel: an
/// exception that is not handled explicitly is fatal.
export fn voryn_exception_handler(vector: u64, frame: *const Registers) callconv(.c) void {
    const processor = frame_layout.processorFrame(voryn_exception_error_code, frame);

    serial.printLine("[VNK] EXCEPTION {d}: {s}", .{ vector, vectorName(vector) });
    serial.printLine("[VNK]   error code: 0x{x}", .{processor.error_code});
    serial.printLine("[VNK]   faulting address: 0x{x}", .{cpu.readCr2()});

    // The page fault is the fault that needs context the most: the report
    // shows how the page that caused the fault is mapped.
    if (vector == 14) {
        const paging = @import("paging.zig");
        paging.describe(cpu.readCr2());
    }
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

    // The exception that came from the user mode is a defect of the process,
    // and not a defect of the kernel: the process is killed, and the kernel
    // continues. An exception in the kernel is fatal, because the state of
    // the kernel is unknown, and continuing from it is worse than stopping.
    if (processor.cs == user_code_selector) {
        const scheduler = @import("../../task/scheduler.zig");

        // An exception of the user mode without a current task is a state
        // that the kernel does not know how to handle: without the task
        // there is no kernel stack to rewrite the frame to, and the machine
        // stops.
        const task = scheduler.scheduler.current orelse {
            serial.printLine("[VNK] FATAL: an exception of the user mode without a current task", .{});
            port.haltForever();
        };

        scheduler.scheduler.killCurrent();

        serial.printLine("[VNK]   the process {d} was killed, and the kernel continues", .{task.id});

        // The killed task does not go back to the code that failed: the
        // frame of the processor is rewritten to the loop of the kernel,
        // and the task stays there until the timer takes it out of there.
        // The scheduler does not choose it again, because it is
        // terminated.
        rewriteFrame(frame, task.kernel_rsp);

        return;
    }

    port.haltForever();
}

/// Rewrites the frame of the processor to the loop of the killed task.
///
/// The frame of the processor is inside the frame of the handler, and the
/// handler writes in it the address of return, the code segment, the stack
/// pointer and the stack segment.
///
/// The killed task enters the loop of the kernel, at level 0, with the
/// kernel stack of the task. The flags are not touched: the loop waits for
/// an interruption with the `hlt`, and the timer is what takes the task out
/// of there.
fn rewriteFrame(frame: *const Registers, kernel_stack: u64) void {
    const base = @intFromPtr(frame) + @sizeOf(Registers);
    const pointer = base + 8;

    const rip: *u64 = @ptrFromInt(pointer);
    const cs: *u64 = @ptrFromInt(pointer + 8);
    const rsp: *u64 = @ptrFromInt(pointer + 24);
    const ss: *u64 = @ptrFromInt(pointer + 32);

    rip.* = @intFromPtr(&voryn_killed_task_loop);
    cs.* = kernel_code_selector;
    rsp.* = kernel_stack;
    ss.* = kernel_data_selector;
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

            // A espera bloqueante de entrada pendente recebe o evento ou
            // expira antes de o escalonador escolher a próxima tarefa.
            const syscall = @import("syscall.zig");
            syscall.inputWaitTick();

            // The waits whose deadline has passed expire before the
            // scheduler chooses the next task, so that a task that timed
            // out is ready in this tick. The result of the expired call is
            // the error of the timeout of the contract of the calls.
            const scheduler = @import("../../task/scheduler.zig");
            const must_switch = scheduler.scheduler.tick(syscall.failure(syscall.Error.timeout));
            timer.acknowledge(@intCast(vector));
            return if (must_switch) 1 else 0;
        }

        if (vector == first_hardware_vector + 1) {
            @import("../../input/ps2.zig").onInterrupt();
        }
        timer.acknowledge(@intCast(vector));
    }

    return 0;
}

/// Loads the interrupt descriptor table.
extern fn voryn_load_idt(pointer: *align(8) const IdtPointer) callconv(.c) void;

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
