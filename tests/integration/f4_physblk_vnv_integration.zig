//************************************************************************//
//  phys_blk_vnv_integration.zig                                          //
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

//! Integration test: PhysBlock (F4 driver) -> block.Device -> VNV commit/\n//! recover. Verifies that a physical driver interface can substitute the\n//! ramdisk without altering the volume or filesystem.\n
const std = @import("std");
const block = @import("../../kernel/storage/block.zig");
const phys_blk = @import("../../kernel/storage/phys_blk.zig");
const ramfs = @import("../../kernel/fs/ramfs.zig");
const vnv_volume = @import("../../kernel/fs/vnv_volume.zig");

const backing_size = 4096 * 512; // 2 MiB

test "f4_physblk_integration_commit_recover" {
    var backing: [backing_size]u8 = undefined;
    @memset(&backing, 0);

    var blk: phys_blk.PhysBlock = .{};
    blk.init(&blk, &backing, 1);
    const device: block.Device = blk.device();

    // Build a minimal RamFS state
    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    const root = try ramfs.createDirectoryFor(&state, ramfs.root_inode, "test");
    const file = try ramfs.createFileFor(&state, root, "hello");
    try ramfs.writeFileFor(&state, file, "F4 verified");

    var staging: [vnv_volume.vnv.image_size]u8 = undefined;
    try vnv_volume.commit(&device, &state, 1, &staging);

    // Recover into a fresh state
    var recovered: ramfs.State = undefined;
    var scratch: ramfs.State = undefined;
    ramfs.initState(&recovered);
    try vnv_volume.recover(&device, &recovered, &staging, &scratch);

    const target = try ramfs.resolvePathFor(&recovered, "/test/hello");
    var buffer: [32]u8 = undefined;
    const count = try ramfs.readFileFor(&recovered, target, &buffer);
    try std.testing.expectEqualStrings("F4 verified", buffer[0..count]);
}
