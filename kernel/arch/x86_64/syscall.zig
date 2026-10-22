//************************************************************************//
//  syscall.zig                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

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
const capability = @import("../../security/capability.zig");
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
    ///
    /// The arguments are the identifier of the channel, the side of the
    /// channel that receives the message, the type of the message and the
    /// value of the message. The value travels in the eighth register,
    /// because the instruction of the call replaces the fourth register
    /// with the address of return.
    pub const send: u64 = 5;
    /// The call that takes a message from a channel.
    pub const receive: u64 = 6;
    /// The call that takes a message from a channel and **blocks** the
    /// caller until the message arrives.
    ///
    /// The arguments are the identifier of the channel and the side of the
    /// channel that holds the message. The result is the type of the
    /// message, and the value of the message comes back in the `RDX`.
    ///
    /// The call that blocks is different from the one that does not: the
    /// task that waits **is not** kept awake, and the scheduler chooses
    /// another one. The message delivers the result straight into the
    /// context saved of the task, and the task continues after the call, as
    /// if the call had answered at once.
    pub const receive_blocking: u64 = 8;
    /// The call that copies a block of memory from the process of the caller
    /// into the space of another process.
    ///
    /// The arguments are the identifier of the target process, the address of
    /// the destination in the space of the target, the address of the origin
    /// in the space of the caller, and the length of the block.
    ///
    /// The length travels in the eighth register and not in the fourth one,
    /// because the instruction of the call replaces the fourth register with
    /// the address of return.
    pub const copy_to: u64 = 7;
    /// The call that gives a capability of the caller to another process.
    ///
    /// The arguments are the identifier of the target process, the
    /// identifier of the subject of the capability — the channel — and the
    /// rights that the target receives.
    ///
    /// The caller has to hold the capability with the right of delegation,
    /// and the rights that the target receives have to be a subset of the
    /// rights that the caller holds. The right of delegation is not part of
    /// what the target receives, unless the caller asks for it explicitly.
    pub const grant: u64 = 9;
    /// The call that takes a capability back from another process.
    ///
    /// The arguments are the identifier of the target process and the
    /// identifier of the subject of the capability — the channel.
    ///
    /// The caller has to hold the capability with the right of delegation:
    /// the owner of the capability takes it back from the process it gave it
    /// to.
    pub const revoke: u64 = 10;
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
    /// The process does not exist.
    pub const unknown_process: u64 = 8;
    /// The wait is impossible.
    ///
    /// The task waited for a message and there was no other task to run,
    /// and the wait would be a busy loop.
    pub const wait_impossible: u64 = 9;
    /// The process does not hold the capability that the call needs.
    ///
    /// The error says that the process does not hold the capability of the
    /// channel that the call names. The process that does not hold it
    /// cannot use the channel, and the capability is what the owner of the
    /// channel gave to the processes that may use it.
    pub const not_authorized: u64 = 10;
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
/// The function is the interface of the kernel with the channel, and the
/// module of the channel is imported in a single place, so that the state of
/// the channel does not depend on the import path.
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

/// The number of cycles between a message being sent and the message being
/// delivered to the task that was waiting for it.
pub fn channelDeliveryLatency(channel_id: u64, side: u64) u64 {
    const channel = channel_module.get(channel_id) orelse return 0;
    return channel.deliveryLatency(side);
}

/// The number of messages that arrived at a task that was waiting.
pub fn channelDeliveries(channel_id: u64, side: u64) u64 {
    const channel = channel_module.get(channel_id) orelse return 0;
    return channel.deliveries(side);
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
/// The result of the call is returned in the first register, and the
/// negative value of an error tells that the call failed.
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
            frame.rax = send(frame.rdi, frame.rsi, frame.rdx, frame.r8, privilege);
            serial.printLine("[VNK] syscall {d} from {s} sent 0x{x} of the type {d} to the side {d}", .{
                number,
                caller,
                frame.rax,
                frame.rdx,
                frame.rsi,
            });
        },
        Number.receive => {
            frame.rax = receive(frame, frame.rdi, frame.rsi, privilege);
            serial.printLine("[VNK] syscall {d} from {s} received 0x{x}", .{
                number,
                caller,
                frame.rax,
            });
        },
        Number.receive_blocking => {
            frame.rax = receiveBlocking(frame, frame.rdi, frame.rsi, privilege);
            serial.printLine("[VNK] syscall {d} from {s} received 0x{x}", .{
                number,
                caller,
                frame.rax,
            });
        },
        Number.grant => {
            frame.rax = grant(frame.rdi, frame.rsi, frame.rdx, privilege);
            serial.printLine("[VNK] syscall {d} from {s} gave the channel {d} to the process {d}", .{
                number,
                caller,
                frame.rsi,
                frame.rdi,
            });
        },
        Number.revoke => {
            frame.rax = revoke(frame.rdi, frame.rsi, privilege);
            serial.printLine("[VNK] syscall {d} from {s} took the channel {d} back from the process {d}", .{
                number,
                caller,
                frame.rsi,
                frame.rdi,
            });
        },
        Number.copy_to => {
            frame.rax = copyTo(frame.rdi, frame.rsi, frame.rdx, frame.r8, privilege);
            serial.printLine("[VNK] syscall {d} from {s} copied 0x{x} bytes to the process {d}", .{
                number,
                caller,
                frame.rax,
                frame.rdi,
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
/// The value is a negative number, and its absolute value is the code of
/// the error.
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
/// is legitimate. The instruction of the copy is the one of a move, and
/// not the one of a copy, because a copy requires that the two ranges do
/// not overlap, and the requirement raises a panic in the kernel, which
/// stops the machine: a task of the user mode would be able to bring the
/// system down with two arguments.
fn memcpy(destination: u64, source: u64, length: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);
    if (length == 0 or length > max_block_length) return failure(Error.invalid_length);
    if (!paging.isUserRange(source, length, false)) return failure(Error.invalid_address);
    if (!paging.isUserRange(destination, length, true)) return failure(Error.invalid_address);

    const from: [*]const u8 = @ptrFromInt(source);
    const to: [*]u8 = @ptrFromInt(destination);

    // The ranges may overlap, and the user chooses the two addresses: a
    // copy that ignored the overlap would corrupt the data, and a copy
    // that refused the overlap would deny a call that is legitimate.
    //
    // The direction of the copy depends on which of the two ranges is
    // above: a copy that always goes backwards destroys the origin when
    // the destination is below it, and a copy that always goes forward
    // destroys the origin when the destination is above it. The move of
    // the memory knows the two cases, and the copy uses it.
    @memmove(to[0..@intCast(length)], from[0..@intCast(length)]);

    return length;
}

/// Puts a message in a channel.
///
/// The arguments are the identifier of the channel, the type of the
/// message and the value of the message. The result is zero, and the
/// negative value of an error means that the message was not sent.
fn send(channel_id: u64, side: u64, kind: u64, value: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);

    const channel = channel_module.get(channel_id) orelse
        return failure(Error.unknown_channel);

    // The process that does not hold the capability of the channel does
    // not put messages in it.
    const process = callerProcess() orelse return failure(Error.not_authorized);
    if (!checkCapability(process, channel_id, capability.Rights.send)) {
        return failure(Error.not_authorized);
    }

    const message = channel_module.Message{ .kind = kind, .value = value };

    // The message goes straight to the task that waits for the queue, and
    // it does not stay in the queue: the delivery writes the result into
    // the context saved of the task, and the task wakes up. With no task
    // waiting, the message stays in the queue. The path is the same in the
    // two cases, and therefore it is what marks the moment the message
    // leaves.
    const sent = channel.post(side, message);
    if (!sent) {
        return failure(Error.full_queue);
    }

    return 0;
}

/// The identifier of the process of the caller, or null when the caller
/// does not belong to a process.
///
/// The function is the way the calls of the user mode find the process that
/// made them. The capability of a process belongs to the process, and not
/// to the task: two tasks of the same process share the same capability.
fn callerProcess() ?u64 {
    const scheduler = @import("../../task/scheduler.zig");
    const task = scheduler.scheduler.current orelse return null;
    const space = task.space orelse return null;
    return space.id;
}

/// Checks that the process of the caller holds the capability of the
/// channel, with the right that the call needs.
///
/// The function is the enforcement of the model of capabilities: a process
/// that does not hold the capability of a channel does not use the channel,
/// whatever the identifier of the channel is.
fn checkCapability(process: u64, channel_id: u64, right: u64) bool {
    return capability.holdsSubject(process, .channel, channel_id, right);
}

/// Takes a message from a channel.
///
/// The argument is the identifier of the channel. The result is the type
/// of the message, and the second result, in the register RDX, is the
/// value of the message. An empty queue answers with the error of the
/// empty queue.
fn receive(frame: *SyscallFrame, channel_id: u64, side: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);

    // The process that does not hold the capability of the channel does
    // not take messages of it.
    const process = callerProcess() orelse return failure(Error.not_authorized);
    if (!checkCapability(process, channel_id, capability.Rights.receive)) {
        return failure(Error.not_authorized);
    }

    const channel = channel_module.get(channel_id) orelse
        return failure(Error.unknown_channel);

    const message = channel.receiveFrom(side) orelse
        return failure(Error.empty_queue);

    frame.rdx = message.value;
    return message.kind;
}

/// Takes a message from a channel, blocking the caller until it arrives.
///
/// The function has the same arguments as the receive that does not block,
/// and the difference is what happens when the queue is empty: the caller
/// **waits**. The wait is registered in the queue, the task is marked as
/// blocked, and the scheduler chooses another task.
///
/// When the message arrives, the delivery writes the type and the value
/// directly in the saved context of the waiting task, and the task
/// becomes ready. The task continues after the call, with the result of
/// the call in the same registers as a call that had answered at once.
///
/// The function returns the type of the message when the queue already had
/// one, and zero when the caller was left waiting: the result really
/// arrives later, in the context saved of the task.
fn receiveBlocking(frame: *SyscallFrame, channel_id: u64, side: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);

    // The process that does not hold the capability of the channel does
    // not wait for a message of it.
    const process = callerProcess() orelse return failure(Error.not_authorized);
    if (!checkCapability(process, channel_id, capability.Rights.receive)) {
        return failure(Error.not_authorized);
    }

    const channel = channel_module.get(channel_id) orelse
        return failure(Error.unknown_channel);

    if (!channel.isEmpty(side)) {
        const message = channel.receiveFrom(side) orelse
            return failure(Error.empty_queue);
        frame.rdx = message.value;
        return message.kind;
    }

    // The queue is empty: the task waits for the message.
    const scheduler = @import("../../task/scheduler.zig");
    if (!scheduler.scheduler.blockCurrent(channel, side)) {
        return failure(Error.wait_impossible);
    }

    // The task is now waiting: the result arrives later, in the context
    // saved of the task, and the return value is irrelevant.
    return 0;
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

/// Copies a block of memory from the space of the caller into the space of
/// another process.
///
/// The two spaces do not name the same physical pages, therefore the kernel
/// cannot copy the block with a single move: it reads the origin with the
/// space of the caller active, holds the block in a buffer of the kernel,
/// and writes the destination with the space of the target active.
///
/// The buffer lives in the image of the kernel, and the image is mapped in
/// every space, therefore the buffer is reachable in both directions of the
/// switch.
///
/// The two ranges are checked in the tables of their own space before the
/// copy, and the space of the caller is restored at the end, whatever the
/// result of the copy is.
fn copyTo(process: u64, destination: u64, source: u64, length: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);
    if (length == 0 or length > max_block_length) return failure(Error.invalid_length);

    const target = paging.spaceById(process) orelse return failure(Error.unknown_process);

    // The origin belongs to the space of the caller, and the destination
    // belongs to the space of the target.
    const caller = paging.activeSpace() orelse return failure(Error.not_allowed);
    if (!paging.isUserRangeIn(caller, source, length, false)) return failure(Error.invalid_address);
    if (!paging.isUserRangeIn(target, destination, length, true)) return failure(Error.invalid_address);

    const saved = cpu.readCr3();
    const saved_space = paging.activeSpace();

    // The origin is read with the space of the caller active.
    const origin: [*]const u8 = @ptrFromInt(source);
    @memcpy(copy_buffer[0..@intCast(length)], origin[0..@intCast(length)]);

    // The destination is written with the space of the target active.
    paging.activateSpace(target);
    const target_address: [*]u8 = @ptrFromInt(destination);
    @memcpy(target_address[0..@intCast(length)], copy_buffer[0..@intCast(length)]);

    // The space of the caller is restored, whatever happened above.
    cpu.writeCr3(saved);
    paging.setActiveSpace(saved_space);

    return length;
}

/// Gives a capability of the caller to another process.
///
/// The arguments are the identifier of the target process, the identifier
/// of the subject of the capability — the channel — and the rights that the
/// target receives.
///
/// The caller has to hold the capability of the subject with the right of
/// delegation. The rights that the target receives have to be a subset of
/// the rights that the caller holds, and the right of delegation is not
/// part of them unless the caller asks for it explicitly.
fn grant(process_id: u64, channel_id: u64, rights: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);

    const target = paging.spaceById(process_id) orelse
        return failure(Error.unknown_process);
    const caller = callerProcess() orelse return failure(Error.not_authorized);

    // The channel that does not exist and the capability that the caller
    // does not hold are two different refusals: the first says that the
    // subject does not exist, and the second says that the caller has no
    // permission over it.
    if (channel_module.get(channel_id) == null) return failure(Error.unknown_channel);

    const handle = capability.handleOf(caller, .channel, channel_id) orelse
        return failure(Error.not_authorized);

    if (!capability.transfer(caller, target.id, handle, rights)) {
        return failure(Error.not_authorized);
    }

    return 0;
}

/// Takes a capability back from another process.
///
/// The arguments are the identifier of the target process and the identifier
/// of the subject of the capability — the channel.
///
/// The caller has to hold the capability of the subject with the right of
/// delegation: the owner of the capability takes it back from the process
/// it gave it to.
fn revoke(process_id: u64, channel_id: u64, privilege: u64) u64 {
    if (privilege != Privilege.user) return failure(Error.not_allowed);

    const target = paging.spaceById(process_id) orelse
        return failure(Error.unknown_process);
    const caller = callerProcess() orelse return failure(Error.not_authorized);

    // The channel that does not exist and the capability that the caller
    // does not hold are two different refusals: the first says that the
    // subject does not exist, and the second says that the caller has no
    // permission over it.
    if (channel_module.get(channel_id) == null) return failure(Error.unknown_channel);

    const handle = capability.handleOf(caller, .channel, channel_id) orelse
        return failure(Error.not_authorized);

    if (!capability.revoke(caller, target.id, handle)) {
        return failure(Error.not_authorized);
    }

    return 0;
}

/// The buffer that holds the block of a copy between two processes.
///
/// The buffer lives in the image of the kernel, and the image is mapped in
/// every space of every process, therefore it is reachable with the space of
/// the caller and with the space of the target active.
var copy_buffer: [max_block_length]u8 align(16) = undefined;
