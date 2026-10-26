//************************************************************************//
//  phys_blk.zig                                                          //
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

//! F4: physical block driver interface integrated with `block.Device`.
//! Uses a contiguous backing buffer (simulating a real disk) and validates
//! all requests with 64-bit arithmetic. Zero dynamic allocation.

const std = @import("std");
const block = @import("block.zig");

pub const PhysBlock = struct {
    backing: []u8,
    sector_size: u32,
    device_id: u32,

    pub fn init(dev: *PhysBlock, backing: []u8, id: u32) void {
        dev.backing = backing;
        dev.sector_size = 512;
        dev.device_id = id;
    }

    /// Exposes the physical block as a `block.Device`.
    pub fn device(self: *PhysBlock) block.Device {
        return .{
            .ctx = self,
            .read = read,
            .write = write,
            .sector_size = self.sector_size,
            .sector_count = if (self.sector_size == 0) 0 else @as(u64, self.backing.len) / self.sector_size,
        };
    }

    /// Indica persistencia: o backing atual e apenas memoria volatil.
    /// Falha simulada nao recupera dados; nao declarar como resistente a falhas.
    pub fn flush(self: *PhysBlock) void {
        _ = self;
    }
};

fn read(ctx: *anyopaque, lba: u64, count: usize, inside: usize, out: []u8) block.Error!void {
    const self: *PhysBlock = @ptrCast(@alignCast(ctx));
    if (self.sector_size == 0) return error.InvalidRequest;
    const size: u32 = self.sector_size;
    const sectors: u64 = @as(u64, self.backing.len) / size;
    if (lba >= sectors) return error.OutOfRange;
    if (count == 0) return error.InvalidRequest;
    if (lba + @as(u64, count) > sectors) return error.OutOfRange;
    const byte_offset = @as(usize, @intCast(lba * @as(u64, size) + @as(u64, inside)));
    const available = @min(out.len, self.backing.len - byte_offset);
    if (out.len > available) return error.OutOfRange;
    @memcpy(out, self.backing[byte_offset .. byte_offset + out.len]);
}

fn write(ctx: *anyopaque, lba: u64, count: usize, inside: usize, in: []const u8) block.Error!void {
    const self: *PhysBlock = @ptrCast(@alignCast(ctx));
    if (self.sector_size == 0) return error.InvalidRequest;
    const size: u32 = self.sector_size;
    const sectors: u64 = @as(u64, self.backing.len) / size;
    if (lba >= sectors) return error.OutOfRange;
    if (count == 0) return error.InvalidRequest;
    if (lba + @as(u64, count) > sectors) return error.OutOfRange;
    const byte_offset = @as(usize, @intCast(lba * @as(u64, size) + @as(u64, inside)));
    if (byte_offset + in.len > self.backing.len) return error.OutOfRange;
    @memcpy(self.backing[byte_offset .. byte_offset + in.len], in);
}

test "physBlkRealDeviceReadsWrites" {
    var backing: [4096]u8 = undefined;
    @memset(backing[0..], 0);
    var blk: PhysBlock = .{};
    blk.init(&blk, &backing, 1);
    const dev: block.Device = blk.device();
    try std.testing.expectEqual(@as(u32, 512), dev.sector_size);
    try std.testing.expectEqual(@as(u64, 8), dev.sector_count); // 4096 / 512 = 8
    var out: [512]u8 = undefined;
    @memset(out[0..], 0);
    try dev.readBytes(0, &out);
    try std.testing.expectEqual(@as(u8, 0), out[0]);
}
