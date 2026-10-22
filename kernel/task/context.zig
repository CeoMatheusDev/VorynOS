//************************************************************************//
//  context.zig                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! The execution context of a task.
//!
//! The context holds **every** register of the processor, and not only the
//! ones that the architecture saves between calls. A task that is preempted
//! in the middle of a system call has to come back with the same value in
//! every register: the result of the call lives in the first register, and
//! the arguments of the next call live in the others. A context that saves
//! only the registers of the callee loses the result of the call, and the
//! task continues with values that belong to another task.
//!
//! The order of the fields is the order of the addresses, which is the
//! reverse of the order of the pushes of the frame that the switch builds.

const std = @import("std");

/// The context of a task.
///
/// It holds the registers of the processor, the state of the processor that
/// a task has to resume with, and the stack pointer of the code that was
/// interrupted. The instruction pointer and the flags are part of the
/// context because a task can be suspended in the middle of an interrupt
/// handler, where there is no return address to return to.
pub const Context = extern struct {
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
    /// The vector of the interrupt that suspended the task.
    ///
    /// The value is informative: the handler of the exceptions is fatal, and
    /// the vector is only read to describe the state of the processor.
    vector: u64 = 0,
    /// The stack pointer of the code that was interrupted.
    rsp: u64 = 0,
    /// The flags of the task. The interrupt flag is part of them: a task
    /// that is suspended inside an interrupt handler has to resume with the
    /// interrupts disabled, otherwise the timer would stop.
    rflags: u64 = 0,
    /// The instruction the task continues at.
    rip: u64 = 0,
    /// The code segment of the task.
    cs: u64 = 0,
    /// The stack segment of the task.
    ss: u64 = 0,
    /// The state of the floating point unit and of the vector registers.
    ///
    /// The processor does **not** save that state between the tasks in the
    /// long mode: the state of the unit belongs to the task that is
    /// running, and the switch has to save it and to restore it. Without
    /// that, a task that is preempted in the middle of a copy that the
    /// compiler made with the vector registers resumes with the state of
    /// the other task.
    ///
    /// The area is the one of the instruction `fxsave`, and the
    /// instruction needs it aligned to sixteen bytes.
    fp: [fp_state_size]u8 align(64) = fp_state_initial,
};

/// The size of the area of the state of the floating point unit.
///
/// The area is the one of the instruction `fxsave`, and the form of sixty
/// four bits saves the registers of the vector unit as well.
pub const fp_state_size: usize = 512;

/// The distance, in bytes, between the beginning of the context and the
/// area of the state of the floating point unit.
pub const fp_state_offset: usize = 192;

/// The initial state of the floating point unit.
///
/// The state is the one that the unit has after the instruction `fninit`:
/// the control word with every exception masked (0x037f) and the control
/// and status register of the vector unit with every exception masked and
/// the round to the nearest even (0x1f80). A fresh area of zeros would
/// leave every exception unmasked, and an ordinary operation of a task
/// would raise the exception of the vector unit.
pub const fp_state_initial: [fp_state_size]u8 = blk: {
    var state: [fp_state_size]u8 = @splat(0);
    // The control word of the unit of the floating point.
    state[0] = 0x7f;
    state[1] = 0x03;
    // The control and status register of the vector unit.
    state[24] = 0x80;
    state[25] = 0x1f;
    break :blk state;
};

comptime {
    if (@offsetOf(Context, "fp") != fp_state_offset) {
        @compileError("the state of the floating point unit is not at the offset 192");
    }
}

/// The size of the frame of the processor that the switch builds.
///
/// The frame has the same shape as the frame of the stub of the interrupt:
/// the general purpose registers, the vector, the word of the error code and
/// the frame of the return of the processor.
pub const frame_size: usize = 176;

/// Reads the time stamp counter.
pub fn timestamp() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );

    return (@as(u64, high) << 32) | low;
}
