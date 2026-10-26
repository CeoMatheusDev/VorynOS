//************************************************************************//
//  block.zig                                                              //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
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
const ramdisk = @import("ramdisk.zig");

pub const Error = error{
    /// O dispositivo ou o pedido é inválido (setor zero, contagem zero).
    InvalidRequest,
    /// O intervalo de bytes pedido não cabe no dispositivo.
    OutOfRange,
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
pub const Device = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, lba: u64, count: usize, inside: usize, out: []u8) Error!void,
    write: *const fn (ctx: *anyopaque, lba: u64, count: usize, inside: usize, in: []const u8) Error!void,
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

test "readBytes and writeBytes round trip across sector boundaries" {
    var backing: [512 * 3]u8 = @splat(0);
    var disk = ramdisk.RamDisk.init(&backing, 512);
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
    var disk = ramdisk.RamDisk.init(&backing, 512);
    const device = disk.device();

    var buffer: [8]u8 = undefined;
    try testing.expectError(error.OutOfRange, device.readBytes(1024, &buffer));
    try testing.expectError(error.OutOfRange, device.readBytes(1017, &buffer));
    try testing.expectError(error.OutOfRange, device.writeBytes(1017, &buffer));
    try device.readBytes(0, &.{});
}

test "byte I/O works on unaligned offsets inside one sector" {
    var backing: [512]u8 = @splat(0);
    var disk = ramdisk.RamDisk.init(&backing, 512);
    const device = disk.device();

    const value = "mid-sector";
    try device.writeBytes(3, value);
    var buffer: [value.len]u8 = undefined;
    try device.readBytes(3, &buffer);
    try testing.expectEqualSlices(u8, value, &buffer);
}

test "a device with a zero sector size is rejected" {
    var backing: [512]u8 = @splat(0);
    var disk = ramdisk.RamDisk.init(&backing, 0);
    const device = disk.device();
    var buffer: [8]u8 = undefined;
    try testing.expectError(error.InvalidRequest, device.readBytes(0, &buffer));
    try testing.expectError(error.InvalidRequest, device.writeBytes(0, &buffer));
}
