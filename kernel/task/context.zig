// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! The execution context of a task.
//!
//! The context holds the registers that the architecture does not save
//! between calls, plus the stack pointer. It is the state that a scheduler
//! has to preserve when it takes a task out of the processor and restores
//! when it puts it back.

const std = @import("std");

/// The context of a task.
///
/// It holds the registers that the architecture does not save between calls
/// and the state of the processor that a task has to resume with. The
/// instruction pointer and the flags are part of the context because a task
/// can be suspended in the middle of an interrupt handler, where there is no
/// return address to return to.
pub const Context = extern struct {
    rbx: u64 = 0,
    rbp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    /// The stack pointer of the task.
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
