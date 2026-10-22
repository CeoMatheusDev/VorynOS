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
};

/// The size of the frame of the processor that the switch builds.
///
/// The frame has the same shape as the frame of the stub of the interrupt:
/// the general purpose registers, the vector, the word of the error code and
/// the frame of the return of the processor.
pub const frame_size: usize = 176;

/// Switches the processor from one task to another.
///
/// The registers of the calling task are saved into `from` and the
/// registers of `to` are restored. The routine does not return to the
/// caller: it returns to the point where the target task was suspended.
pub extern fn voryn_context_switch(from: *Context, to: *const Context) callconv(.c) void;

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
