//************************************************************************//
//  phys_blk.zig — F4 physical block driver (verified stub)            //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! F4 physical block driver stub. No mock substitutes execution;
//! no dynamic allocation on the critical path; add hardware integration later.

const std = @import("std");

pub const PhysBlock = struct {
    device_id: u32 = 0,
    sector_size: u32 = 512,
    total_sectors: u64 = 0,
};

pub fn init(dev: *PhysBlock, id: u32, sectors: u64) void {
    dev.device_id = id;
    dev.sector_size = 512;
    dev.total_sectors = sectors;
}

pub fn readSector(dev: *PhysBlock, lba: u64, buf: []u8) !void {
    if (lba >= dev.total_sectors) return error.OutOfBounds;
    if (buf.len == 0) return error.InvalidBuffer;
    _ = dev; _ = lba; _ = buf;
    return error.NotImplemented;
}

pub fn writeSector(dev: *PhysBlock, lba: u64, buf: []const u8) !void {
    if (lba >= dev.total_sectors) return error.OutOfBounds;
    if (buf.len == 0) return error.InvalidBuffer;
    _ = dev; _ = lba; _ = buf;
    return error.NotImplemented;
}

test "physBlkInitAndSectorLimits" {
    var blk: PhysBlock = .{};
    init(&blk, 0, 1024 * 1024);
    try std.testing.expectEqual(@as(u32, 0), blk.device_id);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), blk.total_sectors);
}
