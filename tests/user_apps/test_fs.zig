//************************************************************************//
//  syscall_test.zig — F4: open/write/close/read em RamFS                  //
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

const std = @import("std");

/// Executa uma syscall no VorynOS.
///
/// Convenção de chamada (x86_64, VorynOS):
///   rax = número da syscall
///   rdi = arg1, rsi = arg2, rdx = arg3
///   retorno em rax
///
/// `rcx` e `r11` são destruídos pela instrução `syscall` e por isso devem
/// constar na lista de clobbers. `memory` avisa ao compilador que a memória
/// pode ser lida/escrita pela syscall.
fn syscall(num: u64, arg1: u64, arg2: u64, arg3: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : "rcx", "r11", "memory"
    );
}

export fn _start() noreturn {
    const SYS_FS_OPEN: u64  = 13;
    const SYS_FS_WRITE: u64 = 15;
    const SYS_FS_READ: u64  = 14;
    const SYS_FS_CLOSE: u64 = 16;

    const msg = "Ola VorynOS F4!";
    var read_buf: [16]u8 = undefined;
    const filename = "test.txt\x00";

    // Valor de retorno de erro: -1 interpretado como u64.
    const ERR: u64 = std.math.maxInt(u64);

    // 1. OPEN (modo escrita = 2)
    const fd_write_res = syscall(SYS_FS_OPEN, @intFromPtr(&filename), 2, 0);
    const fd_write = fd_write_res;
    if (fd_write_res == ERR) {
        while (true) {}
    }

    // 2. WRITE
    _ = syscall(SYS_FS_WRITE, fd_write, @intFromPtr(&msg), msg.len);

    // 3. CLOSE
    _ = syscall(SYS_FS_CLOSE, fd_write, 0, 0);

    // 4. OPEN para leitura (modo read_only = 1)
    const fd_read_res = syscall(SYS_FS_OPEN, @intFromPtr(&filename), 1, 0);
    if (fd_read_res == ERR) {
        while (true) {}
    }
    const fd_read = fd_read_res;

    // 5. READ
    const bytes_read = syscall(SYS_FS_READ, fd_read, @intFromPtr(&read_buf), read_buf.len);

    // 6. CLOSE
    _ = syscall(SYS_FS_CLOSE, fd_read, 0, 0);

    // 7. VERIFICAÇÃO
    if (bytes_read == msg.len) {
        // SUCESSO — loop infinito para não sair
        while (true) {}
    }

    while (true) {}
}