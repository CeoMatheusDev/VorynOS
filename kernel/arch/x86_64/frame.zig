//************************************************************************//
//  frame.zig                                                            //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! The frame that the stubs of the interrupts and of the exceptions build.
//!
//! The frame is a **contract** between three parts of the kernel: the stub,
//! which builds it; the handler, which reads it; and the context switch,
//! which saves it and restores it. The three parts read the **same**
//! positions, and this module is where that contract is written.
//!
//! ## A forma do quadro
//!
//! The processor pushes, when the exception happens, the error code (only
//! on the exceptions that have one), the `RIP`, the `CS`, the flags, the
//! `RSP` and the `SS`. The stub pushes, on top of that: a marker, the
//! vector number and the fifteen registers.
//!
//! The frame of the exceptions that **have** an error code is therefore
//! **eight bytes larger** than the frame of the ones that do not, and every
//! offset after the error code changes.
//!
//! The fix is **one single shape**: the stub of an exception **with** an
//! error code saves the code in a known place and moves the five words of
//! the return of the processor **eight bytes down**. The stub of an
//! exception **without** an error code already produces the frame in that
//! shape.
//!
//! After the normalization, the handler, the switch and the return of the
//! processor read the same positions, and the shape of the frame stops
//! being a concern of each call.

const std = @import("std");

/// The register frame that the stubs build.
///
/// The order of the fields is the order of the pushes of the stub, and the
/// last field is the vector, which the stub pushes after the registers.
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

/// The distance, in bytes, between the beginning of the frame of the
/// registers and the word that holds the `RIP`.
///
/// The frame of the processor starts after the fifteen registers, the
/// vector and the marker, and the `RIP` is the first of the five words of
/// retorno do processador.
pub const rip_offset: usize = @sizeOf(Registers) + 8;

/// The distance, in bytes, between the beginning of the frame of the
/// registers and the word that holds the `CS`.
pub const cs_offset: usize = rip_offset + 8;

/// The distance, in bytes, between the beginning of the frame of the
/// registers and the word that holds the flags.
pub const rflags_offset: usize = rip_offset + 16;

/// The distance, in bytes, between the beginning of the frame of the
/// registers and the word that holds the `RSP`.
pub const rsp_offset: usize = rip_offset + 24;

/// The distance, in bytes, between the beginning of the frame of the
/// registers and the word that holds the `SS`.
pub const ss_offset: usize = rip_offset + 32;

/// Reads the frame of the processor from the frame of the registers.
///
/// The frame of the processor has **one single shape**: the stub of an
/// exception **with** an error code moves the five words of the return
/// down, and the stub of an exception **without** an error code already
/// builds the frame in that shape. The error code arrives as an argument,
/// because it is read from the place where the stub saved it.
pub fn processorFrame(error_code: u64, frame: *const Registers) ProcessorFrame {
    const base = @intFromPtr(frame);

    return .{
        .error_code = error_code,
        .rip = readWord(base + rip_offset),
        .cs = readWord(base + cs_offset),
        .rflags = readWord(base + rflags_offset),
        .rsp = readWord(base + rsp_offset),
        .ss = readWord(base + ss_offset),
    };
}

/// Reads a word of the frame.
fn readWord(address: usize) u64 {
    const value: *const u64 = @ptrFromInt(address);
    return value.*;
}

// ---------------------------------------------------------------------------
// The tests of the contract
// ---------------------------------------------------------------------------

test "the frame of the processor is read from the normalized shape" {
    // The frame that a stub builds: fifteen registers, the vector, the
    // marker, and the five words of the return of the processor.
    var memory: [256]u8 align(16) = undefined;
    const base = @intFromPtr(&memory);

    @memset(&memory, 0);

    const registers: *Registers = @ptrFromInt(base);
    registers.vector = 14;
    registers.rax = 0x8;
    registers.rbx = 0x1fc000;

    writeWord(base + rip_offset, 0x1fc10c);
    writeWord(base + cs_offset, 0x1b);
    writeWord(base + rflags_offset, 0x10246);
    writeWord(base + rsp_offset, 0x200000);
    writeWord(base + ss_offset, 0x23);

    const processor = processorFrame(0x6, registers);

    try std.testing.expectEqual(@as(u64, 0x6), processor.error_code);
    try std.testing.expectEqual(@as(u64, 0x1fc10c), processor.rip);
    try std.testing.expectEqual(@as(u64, 0x1b), processor.cs);
    try std.testing.expectEqual(@as(u64, 0x10246), processor.rflags);
    try std.testing.expectEqual(@as(u64, 0x200000), processor.rsp);
    try std.testing.expectEqual(@as(u64, 0x23), processor.ss);
}

test "the offsets of the frame are the ones that the stub builds" {
    // The fifteen registers occupy the first bytes, and the vector comes
    // after them. The frame of the processor starts after the vector and
    // the marker.
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(Registers) - 8);
    try std.testing.expectEqual(@as(usize, 136), rip_offset);
    try std.testing.expectEqual(@as(usize, 144), cs_offset);
    try std.testing.expectEqual(@as(usize, 152), rflags_offset);
    try std.testing.expectEqual(@as(usize, 160), rsp_offset);
    try std.testing.expectEqual(@as(usize, 168), ss_offset);
}

test "the vector is the last word of the frame of the registers" {
    var memory: [256]u8 align(16) = undefined;
    @memset(&memory, 0);

    const registers: *Registers = @ptrFromInt(@intFromPtr(&memory));
    registers.vector = 13;

    const base = @intFromPtr(&memory);
    try std.testing.expectEqual(@as(u64, 13), readWord(base + @sizeOf(Registers) - 8));
}

/// Writes a word of the frame.
fn writeWord(address: usize, value: u64) void {
    const word: *u64 = @ptrFromInt(address);
    word.* = value;
}
