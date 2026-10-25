//************************************************************************//
//  elf_compat.zig — F8 stub: validacao de ELF64 para ABI Linux/x86_64       //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                   //
//************************************************************************//

//! Valida cabecalho ELF64 para compatibilidade com ABI externa (Linux/x86_64).
//! Nenhuma alocacao dinamica.

const std = @import("std");

pub const EM_X86_64: u16 = 62;

/// Verifica se o arquivo ELF e x86_64 (machine = 62).
pub fn isX86_64(data: []const u8) bool {
    if (data.len < 18) return false;
    // e_machine fica nos bytes 18-19 do cabecalho ELF (offset 18 para 64-bit).
    const e_machine: u16 = @as(u16, @intCast(data[18])) | (@as(u16, @intCast(data[19])) << 8);
    return e_machine == EM_X86_64;
}

test "elfCompatX86_64" {
    // Cabecalho minimo: EM_X86_64 = 62 (0x3E) em little-endian.
    var buf: [20]u8 = undefined;
    buf[18] = 0x3E; // 62
    buf[19] = 0x00;
    try std.testing.expect(isX86_64(&buf));
}
