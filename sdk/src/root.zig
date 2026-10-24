//************************************************************************//
//  root.zig                                                              //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! SDK mínimo para aplicações freestanding x86_64 do VorynOS.
//! Não depende de módulos privados do kernel.

pub const syscall = @import("syscall.zig");

/// Contrato público da metadata do display, compartilhado com o kernel.
pub const display = @import("voryn_display");

pub const CapabilityKind = enum(u64) {
    channel = 0,
    process = 1,
};

pub const Right = struct {
    pub const send: u64 = 1;
    pub const receive: u64 = 2;
    pub const delegate: u64 = 4;
    pub const write: u64 = 8;
};

pub fn ping() u64 {
    return syscall.call(syscall.Number.ping, 0, 0, 0, 0).status;
}

pub fn write(bytes: []const u8) u64 {
    return syscall.call(syscall.Number.write, @intFromPtr(bytes.ptr), bytes.len, 1, 0).status;
}

pub fn exit(code: u64) noreturn {
    _ = syscall.call(syscall.Number.exit, code, 0, 0, 0);
    while (true) {}
}

pub fn send(channel: u64, side: u64, kind: u64, value: u64) u64 {
    return syscall.call(syscall.Number.send, channel, side, kind, value).status;
}

pub fn receive(channel: u64, side: u64) syscall.Result {
    return syscall.call(syscall.Number.receive, channel, side, 0, 0);
}

pub fn receiveBlocking(channel: u64, side: u64) syscall.Result {
    return syscall.call(syscall.Number.receive_blocking, channel, side, 0, 0);
}

pub fn receiveTimeout(channel: u64, side: u64, ticks: u64) syscall.Result {
    return syscall.call(syscall.Number.receive_timeout, channel, side, ticks, 0);
}

pub fn copyTo(process: u64, destination: u64, source: []const u8) u64 {
    return syscall.call(syscall.Number.copy_to, process, destination, @intFromPtr(source.ptr), source.len).status;
}

pub fn grant(process: u64, kind: CapabilityKind, subject: u64, rights: u64) u64 {
    return syscall.call(syscall.Number.grant, process, @intFromEnum(kind), subject, rights).status;
}

pub fn revoke(process: u64, kind: CapabilityKind, subject: u64) u64 {
    return syscall.call(syscall.Number.revoke, process, @intFromEnum(kind), subject, 0).status;
}

pub fn fsOpen(path: []const u8, flags: u64) u64 {
    return syscall.call(syscall.Number.fs_open, @intFromPtr(path.ptr), path.len, flags, 0).status;
}

pub fn fsClose(fd: u64) u64 {
    return syscall.call(syscall.Number.fs_close, fd, 0, 0, 0).status;
}

pub fn fsRead(fd: u64, buffer: []u8) u64 {
    return syscall.call(syscall.Number.fs_read, fd, @intFromPtr(buffer.ptr), buffer.len, 0).status;
}

pub fn fsWrite(fd: u64, bytes: []const u8) u64 {
    return syscall.call(syscall.Number.fs_write, fd, @intFromPtr(bytes.ptr), bytes.len, 0).status;
}

pub fn fsCreate(path: []const u8) u64 {
    return syscall.call(syscall.Number.fs_create, @intFromPtr(path.ptr), path.len, 0, 0).status;
}

pub fn fsMkdir(path: []const u8) u64 {
    return syscall.call(syscall.Number.fs_mkdir, @intFromPtr(path.ptr), path.len, 0, 0).status;
}

/// Preenche `info` com a geometria e o formato do display visível.
/// O resultado é o tamanho escrito, ou um código de erro negativo.
pub fn displayInfo(info: *display.DisplayInfo) u64 {
    return syscall.call(
        syscall.Number.display_info,
        @intFromPtr(info),
        @sizeOf(display.DisplayInfo),
        0,
        0,
    ).status;
}

/// Apresenta um retângulo de pixels no display visível.
/// O resultado é zero no sucesso, ou um código de erro negativo.
pub fn present(request: *const display.PresentRequest) u64 {
    return syscall.call(
        syscall.Number.present,
        @intFromPtr(request),
        @sizeOf(display.PresentRequest),
        0,
        0,
    ).status;
}

test {
    _ = @import("syscall.zig");
}
