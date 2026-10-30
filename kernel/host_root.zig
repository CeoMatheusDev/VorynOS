//************************************************************************//
//  host_root.zig                                                         //
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

//! Raiz dos testes de host do sistema de arquivos e do carregador ELF.
//!
//! Os módulos abaixo são puros: não tocam em portas de I/O, em tabelas de
//! página nem em estruturas do processador. Por isso eles compilam para o
//! host e os testes rodam de verdade durante `zig build test`.
//!
//! A raiz fica em `kernel/host_root.zig`, e não dentro de `kernel/fs/`,
//! porque um módulo Zig só pode importar arquivos abaixo do seu próprio
//! diretório raiz. O carregador importa o sistema de arquivos, e os dois
//! precisam de uma raiz comum.

pub const ramfs = @import("fs/ramfs.zig");
pub const fs = @import("fs/fs.zig");
pub const vfsx = @import("fs/vfsx.zig");
pub const vnv = @import("fs/vnv.zig");
pub const vnv_volume = @import("fs/vnv_volume.zig");
pub const block = @import("voryn_block");
pub const ramdisk = @import("storage/ramdisk.zig");
pub const phys_blk = @import("storage/phys_blk.zig");
pub const elf_loader = @import("elf_loader.zig");
pub const native_image = @import("native_image.zig");

const std = @import("std");
const voryn = @import("voryn_shared");
const usermode = voryn.usermode;

test {
    _ = @import("fs/ramfs.zig");
    _ = @import("fs/fs.zig");
    _ = @import("fs/vfsx.zig");
    _ = @import("fs/vnv.zig");
    _ = @import("fs/vnv_volume.zig");
    _ = @import("voryn_block");
    _ = @import("storage/ramdisk.zig");
    _ = @import("storage/phys_blk.zig");
    _ = @import("elf_loader.zig");
    _ = @import("native_image.zig");
}

test "the native image survives the RamFS and fits the load window" {
    var image_buffer: [native_image.max_image_size]u8 = undefined;
    const bytes = try native_image.build(&image_buffer);

    // The image is a valid ET_DYN ELF with two segments, and the data page
    // carries the marker slot that the program fills at run time.
    var segments: [8]voryn.elf64.Segment = undefined;
    var relocations: [8]voryn.elf64.Relocation = undefined;
    const image = try voryn.elf64.parse(bytes, &segments, &relocations);

    try std.testing.expect(image.relocatable);
    try std.testing.expectEqual(@as(u64, 0), image.entry);
    try std.testing.expectEqual(@as(u64, 0), image.base);
    try std.testing.expectEqual(@as(u64, 0x2000), image.end);
    try std.testing.expectEqual(@as(usize, 2), image.segments.len);
    try std.testing.expectEqual(@as(usize, 1), image.relocations.len);

    // The code segment is R+X and the data segment is R+W: the planner
    // refuses a segment that asks for the two permissions at once.
    try std.testing.expect(image.segments[0].isExecutable());
    try std.testing.expect(!image.segments[0].isWritable());
    try std.testing.expect(image.segments[1].isWritable());
    try std.testing.expect(!image.segments[1].isExecutable());

    const window: u64 = 0x200000 - usermode.window_size;
    const plan = try elf_loader.plan(bytes, window, window, usermode.window_size);

    try std.testing.expectEqual(window, plan.entry);
    try std.testing.expectEqual(window, plan.base);
    try std.testing.expectEqual(window + 0x2000, plan.end);
    try std.testing.expectEqual(@as(usize, 2), plan.segment_count);
    try std.testing.expectEqual(@as(usize, 1), plan.relocation_count);
    try std.testing.expectEqual(
        window + native_image.data_virtual_address + native_image.relocation_target_offset,
        plan.relocations[0].offset + plan.load_bias,
    );
    try std.testing.expectEqual(@as(u64, window), plan.segments[0].page_start);
    try std.testing.expectEqual(@as(u64, window + 0x1000), plan.segments[0].page_end);
    try std.testing.expectEqual(@as(u64, window + 0x1000), plan.segments[1].page_start);
    try std.testing.expectEqual(@as(u64, window + 0x2000), plan.segments[1].page_end);

    // The same bytes go through the RamFS, and the loader reads the file
    // back. This is the path that the boot uses, minus the hardware.
    fs.init();
    _ = try fs.mkdir("/apps");
    const descriptor = try fs.create(0, "/apps/hello.elf", 0o755);
    try std.testing.expectEqual(bytes.len, try fs.write(0, descriptor, bytes));
    try fs.close(0, descriptor);

    var read_buffer: [native_image.max_image_size]u8 = undefined;
    const loaded = try elf_loader.planFromRamFs(
        "/apps/hello.elf",
        &read_buffer,
        window,
        window,
        usermode.window_size,
    );

    try std.testing.expectEqual(plan.entry, loaded.entry);
    try std.testing.expectEqual(plan.base, loaded.base);
    try std.testing.expectEqual(plan.end, loaded.end);
    try std.testing.expectEqual(plan.segment_count, loaded.segment_count);
    try std.testing.expectEqual(plan.relocation_count, loaded.relocation_count);
}

test "the physical driver substitutes the ramdisk in the VNV volume" {
    // F4: o volume VNV nao conhece o backend. Este teste commita e recupera
    // um estado de RamFS sobre `phys_blk.PhysBlock`, que e um dispositivo de
    // blocos com setor de 1 byte e a mesma interface do ramdisk. Se o
    // volume dependesse do ramdisk em memoria, o arquivo nao voltaria.
    const backing_size = 4096 * 512;

    var backing: [backing_size]u8 = @splat(0);
    var device_state: phys_blk.PhysBlock = undefined;
    device_state.init(&backing, 1);
    const device: block.Device = device_state.device();

    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    const root = try ramfs.createDirectoryFor(&state, ramfs.root_inode, "test");
    const file = try ramfs.createFileFor(&state, root, "hello");
    try ramfs.writeFileFor(&state, file, "F4 verified");

    var staging: [vnv.image_size]u8 = @splat(0);
    try vnv_volume.commit(&device, &state, 1, &staging);

    // A recuperacao parte de um estado vazio: o conteudo so pode vir do
    // dispositivo, e nao de uma sobra do estado de origem.
    var recovered: ramfs.State = undefined;
    var scratch: ramfs.State = undefined;
    ramfs.initState(&recovered);
    try vnv_volume.recover(&device, &recovered, &staging, &scratch);

    const target = try ramfs.resolvePathFor(&recovered, "/test/hello");
    var buffer: [32]u8 = undefined;
    const count = try ramfs.readFileFor(&recovered, target, &buffer);
    try std.testing.expectEqualStrings("F4 verified", buffer[0..count]);
}
