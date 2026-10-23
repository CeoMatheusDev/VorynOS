// Test runner for RAMFS tests
const std = @import("std");
const fs = @import("ramfs.zig");
const inode = @import("inode.zig");

// Test: block allocation exhaustion
test "block allocation exhaustion" {
    var r: RamFS = .{};
    r.init();

    // Try to allocate many blocks
    var allocated: [32]u64 = undefined;
    var count: u32 = 0;

    var i: u32 = 0;
    while (i < 32) {
        const b = r.ramfs.allocate_block();
        if (b == null) break;
        allocated[i] = b;
        i += 1;
    }
    count = i;

    // Try one more allocation - should fail
    const exhausted_block = r.ramfs.allocate_block();
    if (exhausted_block == null) {
        std.debug("PASS: block allocation exhaustion\n", .{});
    } else {
        std.debug("FAIL: block allocation should have exhausted\n", .{});
    }

    // Free some blocks
    while (count > 0) {
        count -= 1;
        r.ramfs.free_block(allocated[count]);
    }

    // Try allocation again - should succeed
    const recovered_block = r.ramfs.allocate_block();
    if (recovered_block != null) {
        std.debug("PASS: block recovery after free\n", .{});
    } else {
        std.debug("FAIL: block recovery should succeed\n", .{});
    }

    // Verify bitmap is all 0xFF again
    if (r.ramfs_block_bitmap[0] == 0xFF) {
        std.debug("PASS: bitmap consistent after recovery\n", .{});
    } else {
        std.debug("FAIL: bitmap should be all free\n", .{});
    }
}

// Test: inode allocation and type validation
test "inode allocation and type validation" {
    var r: RamFS = .{};
    r.init();

    // Allocate inodes - first ones should be directories
    var dir_inode: u32 = r.ramfs.allocate_inode();
    if (dir_inode != null) {
        if (r.ramfs_inodes[dir_inode].i_type == inode.InodeType.directory) {
            std.debug("PASS: first inode is directory\n", .{});
        } else {
            std.debug("FAIL: first inode should be directory, got: {}\n", r.ramfs_inodes[dir_inode].i_type);
        }
    } else {
        std.debug("FAIL: could not allocate inode\n", .{});
    }

    // Allocate a file inode
    var file_inode: u32 = r.ramfs.allocate_inode();
    if (file_inode != null) {
        if (r.ramfs_inodes[file_inode].i_type == inode.InodeType.file) {
            std.debug("PASS: second inode is file\n", .{});
        } else {
            std.debug("FAIL: second inode should be file, got: {}\n", r.ramfs_inodes[file_inode].i_type);
        }
    } else {
        std.debug("FAIL: could not allocate inode\n", .{});
    }
}
