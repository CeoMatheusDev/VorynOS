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
//! The frame is a **contract** entre três partes do núcleo: o stub, que o
//! monta; o tratador, que o lê; e o switch do contexto, que o salva e o
//! restaura. As três partes leem as **mesmas** posições, e este módulo é
//! onde esse contrato está escrito.
//!
//! ## A forma do quadro
//!
//! O processador empurra, quando a exceção acontece, o código de erro
//! (só nas exceções que têm um), o `RIP`, o `CS`, as flags, o `RSP` e o
//! `SS`. O stub empurra, por cima disso: um marcador, o número do vetor e
//! os quinze registradores.
//!
//! O quadro das exceções que **têm** código de erro é, por isso, **oito
//! bytes maior** do que o das que não têm, e todos os deslocamentos
//! depois do código de erro mudam.
//!
//! A correção é **uma forma só**: o stub de uma exceção **com** código de
//! erro salva o código em um lugar conhecido e move as cinco palavras do
//! retorno do processador **oito bytes para baixo**. O stub de uma
//! exceção **sem** código de erro já produz o quadro nessa forma.
//!
//! Depois da normalização, o tratador, o switch e a volta do processador
//! leem as mesmas posições, e a forma do quadro deixa de ser uma
//! preocupação de cada chamada.

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
/// O quadro do processador começa depois dos quinze registradores, do
/// vetor e do marcador, e o `RIP` é a primeira das cinco palavras do
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
/// O quadro do processador tem **uma forma só**: o stub de uma exceção
/// **com** código de erro move as cinco palavras do retorno para baixo, e
/// o stub de uma exceção **sem** código de erro já monta o quadro nessa
/// forma. O código de erro chega como argumento, porque ele é lido do
/// lugar onde o stub o salvou.
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
    // The fifteen registradores ocupam os primeiros bytes, e o vetor vem
    // depois deles. O quadro do processador começa depois do vetor e do
    // marcador.
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
