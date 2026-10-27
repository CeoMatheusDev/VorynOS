//************************************************************************//
//  block.zig                                                             //
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

//! Camada de bloco do VorynOS: a interface entre o armazenamento físico e
//! os volumes lógicos (VNV, VPK e os backends futuros do VFSX).
//!
//! Um `Device` é uma abstração mínima e sem alocação: ponteiros de função
//! para leitura e escrita de setores, o tamanho do setor e a quantidade de
//! setores. Os helpers `readBytes`/`writeBytes` traduzem um intervalo de
//! bytes em operações de setor, validando limites com aritmética de 64 bits
//! e sem nunca supor alinhamento do chamador.
//!
//! A interface não conhece o formato da imagem (VNV) nem o conteúdo do
//! volume: ela apenas entrega bytes. O driver real (virtio-blk, ATA PIO,
//! ramdisk) implementa as duas funções; o ramdisk em RAM (`ramdisk.zig`)
//! é o backend verificado hoje, e a troca por um driver físico não altera
//! o volume nem o sistema de arquivos.

const std = @import("std");

pub const Error = error{
    /// O dispositivo ou o pedido é inválido (setor zero, contagem zero).
    InvalidRequest,
    /// O intervalo de bytes pedido não cabe no dispositivo.
    OutOfRange,
    /// O controlador concluiu com erro de dispositivo.
    IoFailure,
    /// A espera limitada por uma conclusao expirou.
    IoTimeout,
    /// O controlador ou o formato de pedido ainda nao e suportado.
    NotImplemented,
    /// O dispositivo entrou em estado inseguro e foi colocado em quarentena.
    DeviceFailure,
};

/// Um dispositivo de blocos.
///
/// `ctx` é o contexto opaco do backend; as funções `read` e `write`
/// recebem `ctx` e operam sobre setores a partir de `lba`. O contrato de
/// cada função: `lba + count` nunca ultrapassa `sector_count`, o buffer
/// tem `out.len`/`in.len` bytes e o backend transfere **exatamente** esse
/// número de bytes. O ramdisk copia direto; um driver de disco real faz
/// read-modify-write quando o pedido não cobre o setor inteiro, e reporta
/// erro em vez de uma escrita parcial silenciosa.
/// Default physical backend, installed once by the kernel's device discovery.
/// Existing callers that carry an explicit `Device` are unaffected.
var default_device: ?Device = null;

pub fn installDefault(device: Device) void {
    default_device = device;
}

pub fn defaultDevice() ?Device {
    return default_device;
}

/// Uses the discovered physical device when present; never reports success
/// for the uninitialized path.
pub fn readDefaultBytes(byte_offset: u64, out: []u8) Error!void {
    const device = default_device orelse return error.NotImplemented;
    try device.readBytes(byte_offset, out);
}

pub fn writeDefaultBytes(byte_offset: u64, in: []const u8) Error!void {
    const device = default_device orelse return error.NotImplemented;
    try device.writeBytes(byte_offset, in);
}

pub fn flushDefault() Error!void {
    const device = default_device orelse return error.NotImplemented;
    try device.flushWrites();
}

pub const Device = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, lba: u64, count: usize, inside: usize, out: []u8) Error!void,
    write: *const fn (ctx: *anyopaque, lba: u64, count: usize, inside: usize, in: []const u8) Error!void,
    /// Opcional: sincroniza os dados volateis do controlador com o meio.
    flush: ?*const fn (ctx: *anyopaque) Error!void = null,
    sector_size: u32,
    sector_count: u64,

    /// Capacidade total do dispositivo, em bytes.
    pub fn capacity(self: *const Device) u64 {
        return @as(u64, self.sector_count) * self.sector_size;
    }

    /// Lê um intervalo contíguo de bytes a partir de `byte_offset`.
    ///
    /// O intervalo pode começar e terminar no meio de um setor; a leitura
    /// atravessa as fronteiras de setor sem alinhar o buffer do chamador.
    /// `inside` informa ao backend o deslocamento dentro do setor `lba`,
    /// porque o primeiro pedaço do intervalo nem sempre começa no byte zero
    /// do setor.
    pub fn readBytes(self: *const Device, byte_offset: u64, out: []u8) Error!void {
        try checkRange(self, byte_offset, out.len);
        var offset = byte_offset;
        var remaining: usize = out.len;
        var cursor: usize = 0;
        while (remaining > 0) {
            const size: u64 = self.sector_size;
            const lba = offset / size;
            const inside: usize = @intCast(offset % size);
            const chunk = @min(remaining, @as(usize, size) - inside);
            try self.read(self.ctx, lba, 1, inside, out[cursor .. cursor + chunk]);
            offset += chunk;
            remaining -= chunk;
            cursor += chunk;
        }
    }

    /// Solicita que o backend persista todas as escritas confirmadas.
    /// Backends volateis sem operacao de sincronizacao retornam NotImplemented.
    pub fn flushWrites(self: *const Device) Error!void {
        const flush = self.flush orelse return error.NotImplemented;
        try flush(self.ctx);
    }

    /// Escreve um intervalo contíguo de bytes a partir de `byte_offset`.
    pub fn writeBytes(self: *const Device, byte_offset: u64, in: []const u8) Error!void {
        try checkRange(self, byte_offset, in.len);
        var offset = byte_offset;
        var remaining: usize = in.len;
        var cursor: usize = 0;
        while (remaining > 0) {
            const size: u64 = self.sector_size;
            const lba = offset / size;
            const inside: usize = @intCast(offset % size);
            const chunk = @min(remaining, @as(usize, size) - inside);
            try self.write(self.ctx, lba, 1, inside, in[cursor .. cursor + chunk]);
            offset += chunk;
            remaining -= chunk;
            cursor += chunk;
        }
    }
};

fn checkRange(self: *const Device, byte_offset: u64, length: usize) Error!void {
    if (self.sector_size == 0 or self.sector_count == 0) return error.InvalidRequest;
    if (length == 0) return;
    const capacity = self.capacity();
    if (byte_offset >= capacity) return error.OutOfRange;
    if (length > capacity - byte_offset) return error.OutOfRange;
}

const testing = std.testing;

const TestDisk = struct {
    backing: []u8,
    sector_size: u32,

    fn init(backing: []u8, size: u32) TestDisk {
        return .{ .backing = backing, .sector_size = size };
    }

    fn device(self: *TestDisk) Device {
        return .{
            .ctx = self,
            .read = testRead,
            .write = testWrite,
            .sector_size = self.sector_size,
            .sector_count = if (self.sector_size == 0) 0 else @intCast(self.backing.len / @as(usize, self.sector_size)),
        };
    }
};

fn testRead(ctx: *anyopaque, lba: u64, count: usize, inside: usize, out: []u8) Error!void {
    const self: *TestDisk = @ptrCast(@alignCast(ctx));
    try testRange(self, lba, count, inside, out.len);
    const start = @as(usize, @intCast(lba * @as(u64, self.sector_size))) + inside;
    @memcpy(out, self.backing[start .. start + out.len]);
}

fn testWrite(ctx: *anyopaque, lba: u64, count: usize, inside: usize, input: []const u8) Error!void {
    const self: *TestDisk = @ptrCast(@alignCast(ctx));
    try testRange(self, lba, count, inside, input.len);
    const start = @as(usize, @intCast(lba * @as(u64, self.sector_size))) + inside;
    @memcpy(self.backing[start .. start + input.len], input);
}

fn testRange(self: *const TestDisk, lba: u64, count: usize, inside: usize, length: usize) Error!void {
    if (self.sector_size == 0 or count == 0) return error.InvalidRequest;
    const sectors: u64 = @intCast(self.backing.len / @as(usize, self.sector_size));
    if (lba >= sectors or @as(u64, @intCast(count)) > sectors - lba) return error.OutOfRange;
    const bytes = std.math.mul(usize, count, @as(usize, self.sector_size)) catch return error.OutOfRange;
    if (inside > bytes or length > bytes - inside) return error.OutOfRange;
}

test "readBytes and writeBytes round trip across sector boundaries" {
    var backing: [512 * 3]u8 = @splat(0);
    var disk = TestDisk.init(&backing, 512);
    const device = disk.device();

    const payload = "the quick brown fox jumps over the lazy dog";
    try device.writeBytes(500, payload);
    try testing.expectEqualSlices(u8, payload[0..12], backing[500..512]);
    try testing.expectEqualSlices(u8, payload[12..], backing[512 .. 512 + payload.len - 12]);

    var buffer: [payload.len]u8 = undefined;
    try device.readBytes(500, &buffer);
    try testing.expectEqualSlices(u8, payload, &buffer);
}

test "byte I/O rejects ranges outside the device" {
    var backing: [512 * 2]u8 = @splat(0);
    var disk = TestDisk.init(&backing, 512);
    const device = disk.device();

    var buffer: [8]u8 = undefined;
    try testing.expectError(error.OutOfRange, device.readBytes(1024, &buffer));
    try testing.expectError(error.OutOfRange, device.readBytes(1017, &buffer));
    try testing.expectError(error.OutOfRange, device.writeBytes(1017, &buffer));
    try device.readBytes(0, &.{});
}

test "byte I/O works on unaligned offsets inside one sector" {
    var backing: [512]u8 = @splat(0);
    var disk = TestDisk.init(&backing, 512);
    const device = disk.device();

    const value = "mid-sector";
    try device.writeBytes(3, value);
    var buffer: [value.len]u8 = undefined;
    try device.readBytes(3, &buffer);
    try testing.expectEqualSlices(u8, value, &buffer);
}

test "a device with a zero sector size is rejected" {
    var backing: [512]u8 = @splat(0);
    var disk = TestDisk.init(&backing, 0);
    const device = disk.device();
    var buffer: [8]u8 = undefined;
    try testing.expectError(error.InvalidRequest, device.readBytes(0, &buffer));
    try testing.expectError(error.InvalidRequest, device.writeBytes(0, &buffer));
}
