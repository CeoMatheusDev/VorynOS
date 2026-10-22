/**************************************************************************/
/*  syscall.zig                                                           */
/**************************************************************************/
/*                         This file is part of:                          */
/*                               VorynOS                                  */
/*              https://github.com/CeoMatheusDev/VorynOS                  */
/**************************************************************************/
/* Copyright (C) 2026 VorynOS contributors.                               */
/*                                                                        */
/* SPDX-License-Identifier: GPL-3.0-only                                  */
/**************************************************************************/

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

const channel_module = @import("../../ipc/channel.zig");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
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
/// The mask clears the interrupt flag, the trap flag, the direction flag
/// and the flags of the arithmetic. The reserved bit 1 is not in the mask,
/// because the architecture requires that it is always set.
///
/// The interrupt flag has to be in the mask: the entry point builds the
/// frame of the call on the stack of the kernel, and an interrupt that
/// arrives in the middle of that sequence would write its own frame over
/// the frame of the call.
///
/// The mask does not take the interrupt flag away from the caller: the
/// processor saves the flags in the register R11 **before** it applies the
/// mask, and the return restores the value of R11. A task that runs in the
/// user mode therefore comes back from the call with the interrupts
/// enabled, and the preemptive scheduler keeps choosing it.
const flag_mask: u64 = 0x7FD;

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
    /// path of the call works from the user mode and from the kernel.
    pub const ping: u64 = 1;
    /// The call that writes a buffer of the user mode in the console.
    pub const write: u64 = 2;
    /// The call that copies a block of memory of the user mode.
    pub const memcpy: u64 = 3;
    /// The call that ends the task of the user mode.
    pub const exit: u64 = 4;
    /// The call that puts a message in a channel.
    pub const send: u64 = 5;
    /// The call that takes a message from a channel.
    pub const receive: u64 = 6;
};

/// The result that the kernel answers to the call of the probe.
pub const ping_result: u64 = 0x42;

/// The errors of the calls.
///
/// A call that fails answers with the negative value of the error, and the
/// result of a call that succeeds is never negative.
pub const Error = struct {
    /// The number of the call does not exist.
    pub const unknown_call: u64 = 1;
    /// An address of the call does not belong to the user mode.
    pub const invalid_address: u64 = 2;
    /// The length of the call is zero or larger than the limit.
    pub const invalid_length: u64 = 3;
    /// The call is not allowed for the privilege level of the caller.
    pub const not_allowed: u64 = 4;
    /// The queue of the channel is empty.
    pub const empty_queue: u64 = 5;
    /// The channel does not exist.
    pub const unknown_channel: u64 = 6;
    /// The queue of the channel is full.
    pub const full_queue: u64 = 7;
};

/// The largest block that a call copies in one go.
///
/// The limit keeps the kernel from spending an unbounded time inside a
/// call, and it is the same for the copy and for the write.
pub const max_block_length: u64 = 64 * 1024;

/// The files that the call of write knows.
pub const Descriptor = struct {
    /// The console of the kernel.
    pub const console: u64 = 1;
};

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

/// A message of a channel of the VNX.
pub const Message = channel_module.Message;

/// The sides of a channel of the VNX.
pub const Side = channel_module.Side;

/// Prepares the channels of the VNX.
pub fn initChannels() void {
    channel_module.init();
}

/// Sends a message to a channel of the kernel.
///
/// The function is the interface of the kernel with the channel, e o
/// módulo do canal é importado em um só lugar, para que o estado do canal
/// não dependa do caminho de importação.
pub fn sendMessage(channel_id: u64, side: u64, kind: u64, value: u64) bool {
    const channel = channel_module.get(channel_id) orelse return false;
    return channel.sendTo(side, .{ .kind = kind, .value = value });
}

/// Receives a message from a channel of the kernel.
pub fn receiveMessage(channel_id: u64, side: u64) ?Message {
    const channel = channel_module.get(channel_id) orelse return null;
    return channel.receiveFrom(side);
}

/// Checks whether the queue of a side of a channel is empty.
pub fn channelIsEmpty(channel_id: u64, side: u64) bool {
    const channel = channel_module.get(channel_id) orelse return true;
    return channel.isEmpty(side);
}

/// The number of cycles between the last message that was sent to a side
/// of a channel and the moment of the call.
pub fn channelLatency(channel_id: u64, side: u64) u64 {
    const channel = channel_module.get(channel_id) orelse return 0;
    return channel.latency(side);
}

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
/// The instruction reads the code segment of the kernel from the field of
/// the low half, and the stack segment of the kernel from the value eight
/// bytes above it: "SS just above CS". The table of the kernel has the
/// data segment eight bytes after the code segment, and therefore the
/// selector of the code segment serves for both.
///
/// The field of the high half belongs to the instruction of return, which
/// the kernel does not use: the return of the call is an interrupt return.
/// The value that is written there is the selector of the data segment of
/// the kernel less eight, and it keeps the register meaningful for a
/// future instruction of return.
fn starValue() u64 {
    return (@as(u64, segment.selectors.kernel_data - 8) << 48) |
        (@as(u64, segment.selectors.kernel_code) << 32);
}

/// Programs the registers of model of the system call.
///
/// The instruction `syscall` reads the code segment of the kernel from the
/// low half of the star, the stack segment of the kernel from the value
/// eight bytes above it, and the address of the entry point from the second
/// register.
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
///
/// The result of the call is returned in the first register, e o valor
/// negativo de um erro indica que a chamada falhou.
pub export fn voryn_syscall_handler(frame: *SyscallFrame, privilege: u64) callconv(.c) void {
    const number = frame.rax;

    const caller = switch (privilege) {
        Privilege.user => "user",
        else => "kernel",
    };

    switch (number) {
        Number.ping => {
            serial.printLine("[VNK] syscall {d} from {s}", .{ number, caller });
            frame.rax = ping_result;
        },
        Number.write => {
            frame.rax = write(frame.rdi, frame.rsi, frame.rdx, privilege);
            serial.printLine("[VNK] syscall {d} from {s} wrote 0x{x} bytes", .{
                number,
                caller,
                frame.rax,
            });
        },
        Number.memcpy => {
            frame.rax = memcpy(frame.rdi, frame.rsi, frame.rdx, privilege);
            serial.printLine("[VNK] syscall {d} from {s} copied 0x{x} bytes", .{
                number,
                caller,
                frame.rax,
            });
        },
        Number.exit => {
            serial.printLine("[VNK] syscall {d} from {s}", .{ number, caller });
            exitTask(frame.rdi, privilege);
            frame.rax = 0;
        },
        Number.send => {
            frame.rax = send(frame.rdi, frame.rsi, frame.rdx, privilege);
            serial.printLine("[VNK] syscall {d} from {s} sent 0x{x} at 0x{x}", .{
                number,
                caller,
                frame.rax,
                frame.rcx,
            });
        },
        Number.receive => {
            frame.rax = receive(frame, frame.rdi, privilege);
            serial.printLine("[VNK] syscall {d} from {s} received 0x{x}", .{
                number,
                caller,
                frame.rax,
            });
        },
        else => {
            serial.printLine("[VNK] syscall {d} from {s} is unknown", .{ number, caller });
            frame.rax = failure(Error.unknown_call);
        },
    }
}

/// The value of a call that failed.
///
/// The value is a negative number, e o seu valor absoluto é o código do
/// erro.
pub fn failure(code: u64) u64 {
    return -%code;
}

/// Writes a buffer of the user mode in the console.
///
/// The buffer belongs to the user, and the kernel may not trust the
/// address: the range is checked in the page tables before the read.
fn write(buffer: u64, length: u64, descriptor: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);
    if (descriptor != Descriptor.console) return failure(Error.not_allowed);
    if (length == 0 or length > max_block_length) return failure(Error.invalid_length);
    if (!paging.isUserRange(buffer, length, false)) return failure(Error.invalid_address);

    const bytes: [*]const u8 = @ptrFromInt(buffer);
    serial.write(bytes[0..@intCast(length)]);

    return length;
}

/// Copies a block of memory of the user mode.
///
/// Both ranges are checked in the page tables before the copy, and the
/// copy is made by the kernel, so that the user does not need a routine
/// of its own for it.
///
/// The copy tolerates ranges that overlap: the user chooses the two
/// addresses, and a copy that refused the overlap would deny a call that
/// is legitimate. The instruction of the copy is the one of a move, e
/// não a de uma cópia, porque a cópia exige que as duas faixas não se
/// sobreponham, e a exigência levanta um pânico no núcleo, que para a
/// máquina: uma tarefa do usuário mode seria capaz de derrubar o sistema
/// com dois argumentos.
fn memcpy(destination: u64, source: u64, length: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);
    if (length == 0 or length > max_block_length) return failure(Error.invalid_length);
    if (!paging.isUserRange(source, length, false)) return failure(Error.invalid_address);
    if (!paging.isUserRange(destination, length, true)) return failure(Error.invalid_address);

    const from: [*]const u8 = @ptrFromInt(source);
    const to: [*]u8 = @ptrFromInt(destination);

    // The ranges may overlap, and the user chooses the two addresses: a
    // copy that ignored the overlap would corrupt the data, and a copy
    // that refused the overlap would deny a call that is legitimate. The
    // copy goes backwards when the destination is above the origin.
    const overlap = destination < source + length and source < destination + length;
    if (overlap) {
        var index: u64 = length;
        while (index > 0) {
            index -= 1;
            to[@intCast(index)] = from[@intCast(index)];
        }
    } else {
        @memmove(to[0..@intCast(length)], from[0..@intCast(length)]);
    }

    return length;
}

/// Puts a message in a channel.
///
/// The arguments are the identifier of the channel, the type of the
/// message and the value of the message. The result is zero, and the
/// negative value of an error means that the message was not sent.
fn send(channel_id: u64, kind: u64, value: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);

    const channel = channel_module.get(channel_id) orelse
        return failure(Error.unknown_channel);

    // The message waits in the queue of the other side, and the queue of
    // the user mode is the one that the user receives from.
    const message = channel_module.Message{ .kind = kind, .value = value };
    const sent = channel.sendTo(channel_module.Side.kernel, message);
    if (!sent) {
        return failure(Error.full_queue);
    }

    return 0;
}

/// Takes a message from a channel.
///
/// The argument is the identifier of the channel. The result is the type
/// of the message, and the second result, in the register RDX, is the
/// value of the message. An empty queue answers with the error of the
/// empty queue.
fn receive(frame: *SyscallFrame, channel_id: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);

    const channel = channel_module.get(channel_id) orelse
        return failure(Error.unknown_channel);

    const message = channel.receiveFrom(channel_module.Side.user) orelse {
        serial.printLine("[DBG] receive: the queue of the user is empty", .{});
        return failure(Error.empty_queue);
    };
    serial.printLine("[DBG] receive: the kind is {d} and the value is 0x{x}", .{ message.kind, message.value });
    frame.rdx = message.value;
    return message.kind;
}

/// Ends the task of the user mode.
///
/// The task is marked as terminated, and the scheduler does not choose it
/// again. The processor keeps running the task until the next
/// interruption, and the task does not have to know that it ended.
fn exitTask(code: u64, privilege: u64) void {
    if (privilege != Privilege.user) return;

    const scheduler = @import("../../task/scheduler.zig");
    scheduler.scheduler.terminateCurrent(code);
}
