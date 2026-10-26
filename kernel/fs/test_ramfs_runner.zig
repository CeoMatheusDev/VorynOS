//************************************************************************//
//  test_ramfs_runner.zig                                                 //
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

// Test runner for RAMFS tests
const std = @import("std");
const fs = @import("ramfs.zig");
const inode = @import("inode.zig");

// RamFS is defined in ramfs.zig and exported as `fs.RamFS`.
const RamFS = fs.RamFS;

// Test: block allocation exhaustion
test "block allocation exhaustion" {
    var r = RamFS{};
    r.init();

    var allocated: [32]u64 = undefined;
    var count: usize = 0;

    // Allocate until exhausted or until 32 blocks have been reached.
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const b = r.ramfs.allocate_block() orelse break;
        allocated[i] = b;
        count = i + 1;
    }

    // Try one more allocation; it must fail and return null.
    const exhausted_block = r.ramfs.allocate_block();
    try std.testing.expect(exhausted_block == null);

    // Free the allocated blocks.
    while (count > 0) {
        count -= 1;
        r.ramfs.free_block(allocated[count]);
    }

    // Try allocating again; it must succeed.
    const recovered_block = r.ramfs.allocate_block();
    try std.testing.expect(recovered_block != null);

    // Verify that the bitmap is free again (0xFF).
    // The block_bitmap field must be accessible and contain at least one item.
    try std.testing.expectEqual(@as(u8, 0xFF), r.ramfs.block_bitmap[0]);
}

// Test: inode allocation and type validation
test "inode allocation and type validation" {
    var r = RamFS{};
    r.init();

    // The first inode must be a directory.
    const dir_inode_opt = r.ramfs.allocate_inode();
    try std.testing.expect(dir_inode_opt != null);
    const dir_inode = dir_inode_opt.?; // unwrap seguro após o expect

    try std.testing.expectEqual(
        inode.InodeType.directory,
        r.ramfs_inodes[dir_inode].i_type,
    );

    // The second inode must be a file.
    const file_inode_opt = r.ramfs.allocate_inode();
    try std.testing.expect(file_inode_opt != null);
    const file_inode = file_inode_opt.?;

    try std.testing.expectEqual(
        inode.InodeType.file,
        r.ramfs_inodes[file_inode].i_type,
    );
}
