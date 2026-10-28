//************************************************************************//
//  vnv_volume.zig                                                        //
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

//! Volume VNV sobre um dispositivo de blocos: commit e recuperação.
//!
//! `commit` serializa um `ramfs.State` em uma imagem VNV (`vnv.zig`) e a
//! escreve no dispositivo; `recover` lê a imagem de volta, valida magic,
//! versão, geometria e CRC32, e só então substitui o estado de destino.
//! Uma imagem corrompida nunca altera o destino (`vnv.decode` decodifica
//! em um candidato e valida tudo antes de commitar).
//!
//! O commit é atômico no sentido do formato: a imagem completa é montada no
//! buffer de staging e escrita em setores contíguos a partir do LBA zero.
//! O journal e a troca atômica de duas imagens (anti-power-loss) continuam
//! como trabalho futuro; esta camada entrega a persistência e a
//! recuperação verificadas sobre a camada de bloco, com o ramdisk como
//! backend e um driver físico como substituto direto.

const std = @import("std");
const ramfs = @import("ramfs.zig");
const vnv = @import("vnv.zig");
const block = @import("voryn_block");

pub const Error = error{
    /// O buffer de staging é menor que a imagem VNV.
    BufferTooSmall,
} || block.Error || vnv.Error;

/// Quantidade de setores do dispositivo ocupada por uma imagem VNV.
pub fn requiredSectors(device_sector_size: u32) u64 {
    if (device_sector_size == 0) return 0;
    return (vnv.image_size + device_sector_size - 1) / device_sector_size;
}

/// Serializa o estado e o grava no dispositivo a partir do LBA zero.
pub fn commit(
    device: *const block.Device,
    state: *const ramfs.State,
    sequence: u64,
    staging: []u8,
) Error!void {
    if (staging.len < vnv.image_size) return error.BufferTooSmall;
    _ = try vnv.encode(state, staging[0..vnv.image_size], sequence);
    try device.writeBytes(0, staging[0..vnv.image_size]);
}

/// Lê a imagem do dispositivo, valida e substitui o estado de destino.
///
/// `scratch` é o estado temporário de decodificação fornecido pelo
/// chamador: `ramfs.State` tem ~1 MiB e um local desse tamanho estoura a
/// pilha de boot do kernel. O destino só é tocado depois que a validação
/// completa passou.
pub fn recover(
    device: *const block.Device,
    state: *ramfs.State,
    staging: []u8,
    scratch: *ramfs.State,
) Error!void {
    if (staging.len < vnv.image_size) return error.BufferTooSmall;
    try device.readBytes(0, staging[0..vnv.image_size]);
    try vnv.decode(staging[0..vnv.image_size], state, scratch);
}

const testing = std.testing;
const ramdisk = @import("../storage/ramdisk.zig");

/// Tamanho do buffer de apoio do ramdisk nos testes: 2 MiB, suficiente
/// para a imagem VNV (~1.01 MiB) e folga para os setores posteriores.
const test_backing_bytes: usize = 4096 * 512;

test "commit and recover round trip a volume through the block device" {
    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    const root = try ramfs.createDirectoryFor(&state, ramfs.root_inode, "apps");
    const file = try ramfs.createFileFor(&state, root, "hello.txt");
    try ramfs.writeFileFor(&state, file, "VorynOS");

    var backing: [test_backing_bytes]u8 = @splat(0);
    var disk = ramdisk.RamDisk.init(&backing, 512);
    const device = disk.device();

    var staging: [vnv.image_size]u8 = undefined;
    try commit(&device, &state, 1, &staging);

    // A imagem ocupa o número exato de setores e os setores seguintes
    // permanecem zerados (o commit não escreve além da imagem).
    const occupied: usize = @intCast(requiredSectors(device.sector_size));
    try testing.expectEqual(@as(usize, (vnv.image_size + 511) / 512), occupied);
    try testing.expect(std.mem.allEqual(u8, backing[occupied * 512 ..], 0));

    var recovered: ramfs.State = undefined;
    var scratch: ramfs.State = undefined;
    ramfs.initState(&recovered);
    try recover(&device, &recovered, &staging, &scratch);

    const target = (try ramfs.resolvePathFor(&recovered, "/apps/hello.txt"));
    var buffer: [8]u8 = undefined;
    const count = try ramfs.readFileFor(&recovered, target, &buffer);
    try testing.expectEqualStrings("VorynOS", buffer[0..count]);
}

test "recover from a corrupted image fails and leaves the destination untouched" {
    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    const file = try ramfs.createFileFor(&state, ramfs.root_inode, "data");
    try ramfs.writeFileFor(&state, file, "original");

    var backing: [test_backing_bytes]u8 = @splat(0);
    var disk = ramdisk.RamDisk.init(&backing, 512);
    const device = disk.device();

    var staging: [vnv.image_size]u8 = undefined;
    try commit(&device, &state, 3, &staging);

    // Corrompe um byte no meio do payload da imagem no dispositivo.
    backing[vnv.image_size / 2] ^= 0xFF;

    var recovered: ramfs.State = undefined;
    var scratch: ramfs.State = undefined;
    ramfs.initState(&recovered);
    const target = try ramfs.createFileFor(&recovered, ramfs.root_inode, "sentinel");
    try ramfs.writeFileFor(&recovered, target, "keep");

    try testing.expectError(error.ChecksumMismatch, recover(&device, &recovered, &staging, &scratch));

    // O destino não foi substituído: o arquivo sentinela continua lá e o
    // arquivo original do commit não existe.
    try testing.expectEqual(@as(?u32, target), ramfs.lookupFor(&recovered, ramfs.root_inode, "sentinel"));
    try testing.expectEqual(@as(?u32, null), ramfs.lookupFor(&recovered, ramfs.root_inode, "data"));
}

test "commit writes the sequence into the image header" {
    var state: ramfs.State = undefined;
    ramfs.initState(&state);

    var staging: [vnv.image_size]u8 = undefined;
    var first_backing: [test_backing_bytes]u8 = @splat(0);
    var first_disk = ramdisk.RamDisk.init(&first_backing, 512);
    var second_backing: [test_backing_bytes]u8 = @splat(0);
    var second_disk = ramdisk.RamDisk.init(&second_backing, 512);
    try commit(&first_disk.device(), &state, 7, &staging);
    try commit(&second_disk.device(), &state, 8, &staging);
    try testing.expect(!std.mem.eql(u8, &first_backing, &second_backing));

    // Uma mesma sequência produz uma imagem idêntica (determinismo).
    var third_backing: [test_backing_bytes]u8 = @splat(0);
    var third_disk = ramdisk.RamDisk.init(&third_backing, 512);
    try commit(&third_disk.device(), &state, 7, &staging);
    try testing.expect(std.mem.eql(u8, &first_backing, &third_backing));
}

test "commit and recover reject undersized staging buffers" {
    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    var backing: [test_backing_bytes]u8 = @splat(0);
    var disk = ramdisk.RamDisk.init(&backing, 512);
    const device = disk.device();
    var small: [16]u8 = undefined;
    var scratch: ramfs.State = undefined;
    try testing.expectError(error.BufferTooSmall, commit(&device, &state, 1, &small));
    try testing.expectError(error.BufferTooSmall, recover(&device, &state, &small, &scratch));
}

test "recover from a device smaller than the image fails" {
    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    var staging: [vnv.image_size]u8 = undefined;

    var tiny_backing: [512 * 4]u8 = @splat(0);
    var tiny = ramdisk.RamDisk.init(&tiny_backing, 512);
    const device = tiny.device();
    var scratch: ramfs.State = undefined;
    try testing.expectError(error.OutOfRange, recover(&device, &state, &staging, &scratch));
    try testing.expectError(error.OutOfRange, commit(&device, &state, 1, &staging));
}

test "recover rejects a device with foreign content" {
    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    var staging: [vnv.image_size]u8 = undefined;

    var backing: [test_backing_bytes]u8 = @splat(0xEE);
    var disk = ramdisk.RamDisk.init(&backing, 512);
    const device = disk.device();
    var scratch: ramfs.State = undefined;
    try testing.expectError(error.InvalidMagic, recover(&device, &state, &staging, &scratch));
}
