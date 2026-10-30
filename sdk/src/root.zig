//************************************************************************//
//  root.zig                                                              //
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

//! SDK mínimo para aplicações freestanding x86_64 do VorynOS.
//! Não depende de módulos privados do kernel.

pub const syscall = @import("syscall.zig");

/// Contrato público da metadata do display, compartilhado com o kernel.
pub const display = @import("voryn_display");

/// Contrato público dos eventos de entrada, compartilhado com o kernel.
pub const input = @import("voryn_input");

/// Contrato público do cliente com o compositor, compartilhado com o kernel.
pub const compositor = @import("voryn_compositor");

/// Contrato público da inferência (chamada 24), compartilhado com o kernel.
pub const ai = @import("voryn_ai");

pub const CapabilityKind = enum(u64) {
    channel = 0,
    process = 1,
    display = 2,
    input = 3,
    ai = 4,
};

pub const Right = struct {
    pub const send: u64 = 1;
    pub const receive: u64 = 2;
    pub const delegate: u64 = 4;
    pub const write: u64 = 8;
    pub const read: u64 = 16;
    /// O direito de executar a inferência embarcada (chamada 24).
    pub const execute: u64 = 32;
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
    return syscall.call(syscall.Number.grant, process, @backingInt(kind), subject, rights).status;
}

pub fn revoke(process: u64, kind: CapabilityKind, subject: u64) u64 {
    return syscall.call(syscall.Number.revoke, process, @backingInt(kind), subject, 0).status;
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

/// Shrinks an open file. The descriptor must permit writes.
pub fn fsTruncate(fd: u64, new_size: u64) u64 {
    return syscall.call(syscall.Number.fs_truncate, fd, new_size, 0, 0).status;
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

/// Retira um evento da fila de entrada do serviço gráfico.
/// O resultado é 1 quando um evento foi escrito, 0 quando a fila está
/// vazia, ou um código de erro negativo.
pub fn inputPoll(event: *input.InputEvent) u64 {
    return syscall.call(
        syscall.Number.input_poll,
        @intFromPtr(event),
        @sizeOf(input.InputEvent),
        0,
        0,
    ).status;
}

/// Bloqueia até que um evento de entrada esteja disponível ou o timeout
/// expire (em ticks do timer; zero = espera indefinida).
/// O resultado é 1 quando um evento foi escrito no buffer, ou um código de
/// erro negativo (timeout = 13).
pub fn inputWait(event: *input.InputEvent, ticks: u64) u64 {
    return syscall.call(
        syscall.Number.input_wait,
        @intFromPtr(event),
        @sizeOf(input.InputEvent),
        ticks,
        0,
    ).status;
}

/// Executa o modelo embarcado no kernel sobre `input` e escreve o
/// resultado em `output`.
///
/// O resultado é o número de bytes escritos (12) no sucesso, ou um código
/// de erro negativo: 10 quando o processo não recebeu a capability da IA,
/// 3 quando os tamanhos não são os do contrato, 2 quando um intervalo não
/// pertence ao modo usuário, e 26 quando o kernel recusou o modelo.
pub fn aiInfer(features: []const f32, result: []f32) u64 {
    if (features.len != ai.input_dims) return 0 -% @backingInt(syscall.Error.invalid_length);
    if (result.len < ai.output_dims) return 0 -% @backingInt(syscall.Error.invalid_length);
    return syscall.call(
        syscall.Number.ai_infer,
        @intFromPtr(features.ptr),
        features.len * @sizeOf(f32),
        @intFromPtr(result.ptr),
        result.len * @sizeOf(f32),
    ).status;
}

test {
    _ = @import("syscall.zig");
}

test "the sdk mirrors the geometry of the contract" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 4), ai.input_dims);
    try std.testing.expectEqual(@as(usize, 3), ai.output_dims);
    try std.testing.expectEqual(@as(u64, 24), syscall.Number.ai_infer);
    try std.testing.expectEqual(@as(u64, 4), @backingInt(CapabilityKind.ai));
    try std.testing.expectEqual(ai.right_execute, Right.execute);
}
