//************************************************************************//
//  hello.zig                                                             //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Aplicação nativa mínima produzida pelo toolchain.
//!
//! O programa não usa biblioteca padrão: ele chama o kernel diretamente
//! pelas instruções `syscall`, com os números do contrato de VorynOS. O
//! construtor do kernel não participa da imagem; ela é um ELF64 real,
//! compilado pelo Zig e gravado no RamFS durante o boot.

const std = @import("std");

/// Chama o kernel com três argumentos.
fn syscall3(number: u64, a: u64, b: u64, c: u64) u64 {
    var result: u64 = undefined;
    asm volatile ("syscall"
        : [result] "={rax}" (result),
        : [number] "{rax}" (number),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [c] "{rdx}" (c),
        : .{ .rcx = true, .r11 = true, .memory = true });
    return result;
}

export fn _start() noreturn {
    const message = "toolchain ELF\n";
    _ = syscall3(2, @intFromPtr(message.ptr), message.len, 1);
    _ = syscall3(4, 0, 0, 0);
    while (true) {}
}
