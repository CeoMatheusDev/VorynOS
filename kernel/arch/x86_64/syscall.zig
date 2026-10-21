// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! The system call of the user mode.
//!
//! The call is delivered by the instruction `syscall`, the mechanism that
//! the architecture provides for the mode of 64 bits. The instruction does
//! not go through the interrupt table: it reads the entry point and the
//! segments of the kernel from the registers of model, and it delivers the
//! call on the stack of the caller.
//!
//! The registers of model are three:
//!
//!   * `IA32_STAR` - the code segment of the kernel in the high half, and
//!     the stack segment of the kernel in the half below it;
//!   * `IA32_LSTAR` - the address of the entry point of the call;
//!   * `IA32_SFMASK` - the flags that the processor clears while the call
//!     is handled.
//!
//! The entry point is in `syscall.s`. It saves the state of the caller in a
//! frame, calls the handler of this module, and gives the state back. The
//! handler runs on the stack of the kernel of the task, and never on the
//! stack of the user, which the user could rewrite.
//!
//! **The instruction is the door of the user mode, and the kernel does not
//! use it.** The instruction replaces the code and the stack segments of the
//! caller by the ones of the kernel before it delivers the call, therefore
//! the entry point cannot tell the privilege level of the caller by the
//! selector of the code segment: the selector is always the one of the
//! kernel. The kernel calls the handler of this module directly, and the
//! entry point always returns to the user mode.
//!
//! The interface between the entry point and this module is the frame:
//!
//! ```text
//! offset  field   content
//! 0       r15     general purpose register
//! 8       r14     general purpose register
//! 16      r13     general purpose register
//! 24      r12     general purpose register
//! 32      r11     general purpose register, and the flags of the caller
//! 40      r10     general purpose register
//! 48      r9      general purpose register
//! 56      r8      general purpose register
//! 64      rbx     general purpose register
//! 72      rbp     general purpose register
//! 80      rdi     first argument of the call
//! 88      rsi     second argument of the call
//! 96      rdx     third argument of the call
//! 104     rcx     address of return of the caller
//! 112     rax     number of the call, and the result of the call
//! ```

const std = @import("std");
const voryn = @import("voryn_shared");

const serial = voryn.serial;

const cpu = @import("cpu.zig");
const segment = @import("segment.zig");

/// The register of the extended features of the processor.
const msr_efer: u32 = 0xC000_0080;

/// The register of the star of the system call.
const msr_star: u32 = 0xC000_0081;

/// The register of the address of the entry point of the system call.
const msr_lstar: u32 = 0xC000_0082;

/// The register of the mask of the flags of the system call.
const msr_sfmask: u32 = 0xC000_0084;

/// The bit that enables the instruction of the system call.
const efer_sce: u64 = 1 << 0;

/// The flags that the processor clears while the call is handled.
///
/// The mask clears the trap flag and the direction flag. The interrupt flag
/// is not in the mask, because the flags of the caller are restored when
/// the call returns, and a task that runs in the user mode has to stay
/// preemptible: with the interrupt flag in the mask, the task would come
/// back from the call with the interrupts disabled and the preemptive
/// scheduler would never choose it again. The reserved bit 1 is not in the
/// mask either, because the architecture requires that it is always set.
const flag_mask: u64 = 0x500;

/// The state of the caller at the entry of a system call.
///
/// The fields are in the order of the addresses, which is the reverse of the
/// order of the pushes of the entry point.
pub const SyscallFrame = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    /// The flags of the caller, saved by the processor in the register R11.
    r11: u64 = 0,
    r10: u64 = 0,
    r9: u64 = 0,
    r8: u64 = 0,
    rbx: u64 = 0,
    rbp: u64 = 0,
    /// The first argument of the call.
    rdi: u64 = 0,
    /// The second argument of the call.
    rsi: u64 = 0,
    /// The third argument of the call.
    rdx: u64 = 0,
    /// The address of return of the caller.
    rcx: u64 = 0,
    /// The number of the call, and the result of the call.
    rax: u64 = 0,
};

/// The numbers of the calls of the kernel.
///
/// The numbers are the ones of the first increment of the interface, and
/// they are the ones that the program of the user mode uses.
pub const Number = struct {
    /// The call that answers with a known value, used to prove that the
    /// path of the call works from the user mode.
    pub const ping: u64 = 1;
};

/// The result that the kernel answers to the call of the probe.
pub const ping_result: u64 = 0x42;

/// The privilege level of the caller.
///
/// The entry point of the call always delivers the call of the user mode,
/// and the kernel calls the handler directly.
pub const Privilege = struct {
    /// The caller runs in the kernel.
    pub const kernel: u64 = 0;
    /// The caller runs in the user mode.
    pub const user: u64 = 3;
};

/// The entry point of the call, provided by the assembly.
extern var voryn_syscall_instruction_entry: u8;

// The selectors of the user mode are written in the entry point of the
// call, and the check below makes sure that the two cannot drift apart.
comptime {
    if (segment.selectors.user_code != 0x1b) {
        @compileError("the entry point of the call uses the code selector 0x1b");
    }
    if (segment.selectors.user_data != 0x23) {
        @compileError("the entry point of the call uses the data selector 0x23");
    }
}

/// The value of the register of the star.
///
/// The instruction reads the code segment of the kernel from the field of the
/// low half, and the stack segment of the kernel from the field of the high
/// half, adding eight to the value of the field. The field of the high half
/// therefore holds the selector of the stack segment of the kernel less
/// eight.
///
/// The emulator that the test uses adds eight to the value of the low half
/// instead, and the table of the kernel has the data segment eight bytes
/// after the code segment: the two rules give the same stack segment, e o
/// valor abaixo serve para o processador e para o emulador.
fn starValue() u64 {
    return (@as(u64, segment.selectors.kernel_data - 8) << 48) |
        (@as(u64, segment.selectors.kernel_code) << 32);
}

/// Programs the registers of model of the system call.
///
/// The instruction `syscall` reads the code segment of the kernel from the
/// low half of the star, the stack segment of the kernel from the high
/// half, and the address of the entry point from the second register.
pub fn install() void {
    cpu.writeMsr(msr_star, starValue());
    cpu.writeMsr(msr_lstar, @intFromPtr(&voryn_syscall_instruction_entry));
    cpu.writeMsr(msr_sfmask, flag_mask);

    // The processor only accepts the instruction when the extension of the
    // system call is enabled in the register of the extended features.
    // Without it, the instruction raises an invalid opcode exception.
    cpu.writeMsr(msr_efer, cpu.readMsr(msr_efer) | efer_sce);
}

/// The value of the star of the system call, for the diagnostic output.
pub fn readStar() u64 {
    return cpu.readMsr(msr_star);
}

/// Verifies that the registers of model hold what the kernel programmed.
///
/// The verification reads the registers back, because a register that was
/// not written, or that was written with the wrong value, makes the
/// instruction fail in a way that is hard to diagnose.
pub fn verify() bool {
    if (cpu.readMsr(msr_star) != starValue()) return false;
    if (cpu.readMsr(msr_lstar) != @intFromPtr(&voryn_syscall_instruction_entry)) return false;
    if (cpu.readMsr(msr_sfmask) != flag_mask) return false;
    if (cpu.readMsr(msr_efer) & efer_sce == 0) return false;

    return true;
}

/// The handler of the system calls.
///
/// The handler runs in the kernel, on the stack of the kernel of the task:
/// the user cannot rewrite the frame of the handler.
///
/// `frame` points at the state of the caller, and `privilege` is the level
/// of privilege of the caller, which tells the handler whether the call
/// comes from the user mode or from the kernel.
pub export fn voryn_syscall_handler(frame: *SyscallFrame, privilege: u64) callconv(.c) void {
    const number = frame.rax;
    const argument = frame.rdi;

    const caller = switch (privilege) {
        Privilege.user => "user",
        else => "kernel",
    };

    serial.printLine("[VNK] syscall {d} argument 0x{x} from {s}", .{
        number,
        argument,
        caller,
    });
    serial.printLine("[VNK] syscall {d} flags 0x{x} return 0x{x}", .{
        number,
        frame.r11,
        frame.rcx,
    });

    // The result of the call is returned in the first register.
    frame.rax = ping_result;
}
