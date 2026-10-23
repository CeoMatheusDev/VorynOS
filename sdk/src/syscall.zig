//************************************************************************//
//  syscall.zig                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! Interface de baixo nível da ABI VSC-0001, versão 9.
//! x86_64: RAX=número/resultado, RDI/RSI/RDX/R8=argumentos.
//! RCX e R11 são destruídos pela instrução syscall.

pub const abi_version: u32 = 9;

pub const Number = struct {
    pub const ping: u64 = 1;
    pub const write: u64 = 2;
    pub const memcpy: u64 = 3;
    pub const exit: u64 = 4;
    pub const send: u64 = 5;
    pub const receive: u64 = 6;
    pub const copy_to: u64 = 7;
    pub const receive_blocking: u64 = 8;
    pub const grant: u64 = 9;
    pub const revoke: u64 = 10;
    pub const receive_timeout: u64 = 11;
    // 12 é reservado.
    pub const fs_open: u64 = 13;
    pub const fs_close: u64 = 14;
    pub const fs_read: u64 = 15;
    pub const fs_write: u64 = 16;
    pub const fs_create: u64 = 17;
    pub const fs_mkdir: u64 = 18;
};

pub const Result = struct {
    status: u64,
    value: u64,
};

/// A saída secundária em RDX é relevante para receive*.
/// O código não converte erros negativos em unsigned automaticamente:
/// o chamador recebe os bits exatos da ABI.
pub inline fn call(number: u64, a: u64, b: u64, c: u64, d: u64) Result {
    var status: u64 = undefined;
    var value: u64 = undefined;
    asm volatile ("syscall"
        : [status] "={rax}" (status),
          [value] "={rdx}" (value),
        : [number] "{rax}" (number),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [c] "{rdx}" (c),
          [d] "{r8}" (d),
        : .{ .rcx = true, .r11 = true, .memory = true });
    return .{ .status = status, .value = value };
}

pub fn isError(status: u64) bool {
    return @as(i64, @bitCast(status)) < 0;
}

pub fn errorCode(status: u64) ?u64 {
    if (!isError(status)) return null;
    return 0 -% status;
}

test "ABI call numbers are stable" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 1), Number.ping);
    try std.testing.expectEqual(@as(u64, 11), Number.receive_timeout);
    try std.testing.expectEqual(@as(u64, 13), Number.fs_open);
    try std.testing.expectEqual(@as(u64, 18), Number.fs_mkdir);
    try std.testing.expectEqual(@as(u32, 9), abi_version);
}

test "negative status decoding" {
    const std = @import("std");
    try std.testing.expect(!isError(0));
    try std.testing.expect(!isError(0x42));
    try std.testing.expectEqual(@as(?u64, 13), errorCode(0 -% @as(u64, 13)));
}
