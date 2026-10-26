//************************************************************************//
//  minimal_test.zig                                                      //
//************************************************************************//
//                        This file is part of:                           //
//                              VorynOS                                   //
//             https://github.com/CeoMatheusDev/VorynOS                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 VorynOS - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // Lê o timestamp counter (TSC) via inline assembly.
    // A saída é vinculada ao registrador rax, o tipo de retorno é u64.
    // "rcx" e "r11" são clobbers obrigatórios para a instrução syscall;
    // "memory" impede que o compilador reordene acessos à memória.
    const ret: u64 = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : // sem entradas
        : "rcx", "r11", "memory"
    );

    // Stdout na nova API de I/O (Zig 0.17.0).
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("ret = {d}\n", .{ret});
    try stdout.flush();
}