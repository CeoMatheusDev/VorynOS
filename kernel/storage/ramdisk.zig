//************************************************************************//
//  ramdisk.zig                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Dispositivo de blocos em RAM.
//!
//! O ramdisk serve um `block.Device` sobre um buffer contíguo do kernel.
//! Ele existe por dois motivos: exercitar a camada de bloco e o ciclo de
//! vida de um volume VNV (commit, wipe e recuperação) sem depender de um
//! driver físico, e servir de backend de teste determinístico no host e no
//! QEMU. Um driver de disco real (virtio-blk, ATA PIO) implementa a mesma
//! interface e substitui o ramdisk sem alterar o volume nem o filesystem.
//!
//! O dispositivo não aloca, não usa o heap e nunca escreve fora do buffer:
//! toda operação valida `lba + count` contra `sector_count` antes de tocar
//! a memória.

const block = @import("block.zig");

/// Dispositivo de blocos apoiado em um buffer contíguo.
pub const RamDisk = struct {
    backing: []u8,
    sector_size: u32,

    pub fn init(backing: []u8, sector_size: u32) RamDisk {
        return .{ .backing = backing, .sector_size = sector_size };
    }

    /// Expõe o ramdisk como um `block.Device`.
    pub fn device(self: *RamDisk) block.Device {
        return .{
            .ctx = self,
            .read = read,
            .write = write,
            .sector_size = self.sector_size,
            .sector_count = if (self.sector_size == 0) 0 else self.backing.len / self.sector_size,
        };
    }

    fn read(ctx: *anyopaque, lba: u64, count: usize, inside: usize, out: []u8) block.Error!void {
        const self: *RamDisk = @ptrCast(@alignCast(ctx));
        const slice = try self.region(lba, count, inside, out.len);
        @memcpy(out[0..slice.len], slice);
    }

    fn write(ctx: *anyopaque, lba: u64, count: usize, inside: usize, in: []const u8) block.Error!void {
        const self: *RamDisk = @ptrCast(@alignCast(ctx));
        const slice = try self.region(lba, count, inside, in.len);
        @memcpy(slice, in);
    }

    /// Valida `lba`/`count`/`inside` contra a geometria e devolve a fatia
    /// do buffer.
    ///
    /// O pedido pode cobrir apenas parte de um setor: `inside` é o byte
    /// inicial dentro do setor `lba`, e o ramdisk copia `length` bytes a
    /// partir dele. O restante do setor não é tocado.
    fn region(self: *const RamDisk, lba: u64, count: usize, inside: usize, length: usize) block.Error![]u8 {
        if (self.sector_size == 0) return error.InvalidRequest;
        if (count == 0 or length < count) return error.InvalidRequest;
        const size: u64 = self.sector_size;
        const sectors: u64 = self.backing.len / size;
        // `lba * size` em 64 bits não estoura para `lba < sectors`; o
        // produto é no máximo o tamanho do buffer.
        if (lba >= sectors) return error.OutOfRange;
        if (count > sectors - lba) return error.OutOfRange;
        if (inside >= size) return error.InvalidRequest;
        const byte_count = @as(usize, @intCast(count * size));
        const available = @min(byte_count - inside, length);
        const start: usize = @intCast(lba * size + inside);
        return self.backing[start .. start + available];
    }
};

const testing = @import("std").testing;

test "ramdisk exposes its geometry and rejects writes past the end" {
    var backing: [512 * 4]u8 = @splat(0);
    var disk = RamDisk.init(&backing, 512);
    const device = disk.device();
    try testing.expectEqual(@as(u32, 512), device.sector_size);
    try testing.expectEqual(@as(u64, 4), device.sector_count);
    try testing.expectEqual(@as(u64, 2048), device.capacity());

    var sector: [512]u8 = @splat(0xAB);
    try testing.expectError(error.OutOfRange, device.write(&disk, 4, 1, 0, &sector));
    try testing.expectError(error.OutOfRange, device.write(&disk, 3, 2, 0, &sector));
    try testing.expectError(error.InvalidRequest, device.write(&disk, 0, 0, 0, &.{}));
}

test "ramdisk stores and returns exact sector content" {
    var backing: [512 * 2]u8 = @splat(0);
    var disk = RamDisk.init(&backing, 512);
    const device = disk.device();

    var sector: [512]u8 = @splat(0x5A);
    sector[0] = 1;
    sector[511] = 2;
    try device.write(&disk, 1, 1, 0, &sector);
    try testing.expectEqual(@as(u8, 1), backing[512]);
    try testing.expectEqual(@as(u8, 2), backing[1023]);

    var readback: [512]u8 = undefined;
    try device.read(&disk, 1, 1, 0, &readback);
    try testing.expectEqualSlices(u8, &sector, &readback);
}

test "ramdisk with a zero sector size is invalid" {
    var backing: [512]u8 = @splat(0);
    var disk = RamDisk.init(&backing, 0);
    const device = disk.device();
    try testing.expectEqual(@as(u64, 0), device.sector_count);
    var sector: [8]u8 = @splat(0);
    try testing.expectError(error.InvalidRequest, device.write(&disk, 0, 1, 0, &sector));
    try testing.expectError(error.InvalidRequest, device.read(&disk, 0, 1, 0, &sector));
}
