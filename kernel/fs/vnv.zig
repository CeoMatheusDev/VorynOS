//************************************************************************//
//  vnv.zig                                                                //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only
//************************************************************************//

//! Deterministic, validated VNV image codec for one RamFS volume.
//!
//! This module deliberately stops at a byte codec. It does not claim durable
//! storage: a future block device must provide the image lifecycle and atomic
//! replacement policy. The format is explicit little-endian and never relies
//! on Zig struct layout.

const std = @import("std");
const ramfs = @import("ramfs.zig");
const inode = @import("inode.zig");

pub const magic: u32 = 0x3156_4e56; // "VNV1" in little endian.
pub const version: u16 = 1;
pub const header_size: usize = 64;
pub const inode_record_size: usize = 151;
pub const dir_record_size: usize = 74;
pub const payload_size: usize = ramfs.block_count / 8 +
    ramfs.inode_count * inode_record_size +
    ramfs.dir_entry_count * dir_record_size + ramfs.total_size;
pub const image_size: usize = header_size + payload_size;

pub const Error = error{
    BufferTooSmall,
    InvalidSize,
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    ChecksumMismatch,
    InvalidInodeType,
    InvalidInode,
    InvalidBlock,
    BitmapMismatch,
    InvalidDirectory,
    InvalidName,
};

fn put16(out: []u8, offset: usize, value: u16) void {
    out[offset] = @truncate(value);
    out[offset + 1] = @truncate(value >> 8);
}
fn put32(out: []u8, offset: usize, value: u32) void {
    put16(out, offset, @truncate(value));
    put16(out, offset + 2, @truncate(value >> 16));
}
fn put64(out: []u8, offset: usize, value: u64) void {
    put32(out, offset, @truncate(value));
    put32(out, offset + 4, @truncate(value >> 32));
}
fn get16(input: []const u8, offset: usize) u16 {
    return @as(u16, input[offset]) | (@as(u16, input[offset + 1]) << 8);
}
fn get32(input: []const u8, offset: usize) u32 {
    return @as(u32, get16(input, offset)) | (@as(u32, get16(input, offset + 2)) << 16);
}
fn get64(input: []const u8, offset: usize) u64 {
    return @as(u64, get32(input, offset)) | (@as(u64, get32(input, offset + 4)) << 32);
}

fn inodeOffset(index: usize) usize {
    return header_size + ramfs.block_count / 8 + index * inode_record_size;
}
fn dirOffset(index: usize) usize {
    return header_size + ramfs.block_count / 8 + ramfs.inode_count * inode_record_size + index * dir_record_size;
}
fn memoryOffset() usize {
    return header_size + ramfs.block_count / 8 + ramfs.inode_count * inode_record_size + ramfs.dir_entry_count * dir_record_size;
}

fn checksum(payload: []const u8) u32 {
    return std.hash.Crc32.hash(payload);
}

fn validate(state: *const ramfs.State) Error!void {
    var expected_bitmap: [ramfs.block_count / 8]u8 = @splat(0);
    expected_bitmap[0] = 1;

    for (state.inodes, 0..) |entry, index| {
        const occupied = entry.i_links_count != 0;
        if (!occupied) {
            if (entry.i_size != 0 or entry.i_block[0] != 0) return error.InvalidInode;
            continue;
        }
        if (index == ramfs.root_inode and entry.i_type != .directory) return error.InvalidInode;
        if (entry.i_type != .file and entry.i_type != .directory) return error.InvalidInodeType;
        if (entry.i_size > ramfs.max_file_size) return error.InvalidInode;
        if (entry.i_indirect != 0 or entry.i_double_indirect != 0) return error.InvalidBlock;
        const blocks: usize = (@as(usize, @intCast(entry.i_size)) + ramfs.block_size - 1) / ramfs.block_size;
        if (blocks > ramfs.direct_blocks) return error.InvalidInode;
        for (entry.i_block, 0..) |block, block_index| {
            if (block_index >= blocks) {
                if (block != 0) return error.InvalidBlock;
                continue;
            }
            if (block == 0 or block >= ramfs.block_count) return error.InvalidBlock;
            const bit = @as(u8, 1) << @intCast(block % 8);
            expected_bitmap[block / 8] |= bit;
        }
    }
    if (!std.mem.eql(u8, &expected_bitmap, &state.block_bitmap)) return error.BitmapMismatch;

    for (state.dir_entries, 0..) |entry, entry_index| {
        if (!entry.used) continue;
        if (entry.name_len == 0 or entry.name_len > ramfs.max_name_len) return error.InvalidName;
        for (state.dir_entries[entry_index + 1 ..]) |other| {
            if (other.used and other.parent == entry.parent and other.name_len == entry.name_len and
                std.mem.eql(u8, other.name[0..other.name_len], entry.name[0..entry.name_len])) return error.InvalidDirectory;
        }
        if (entry.parent >= ramfs.inode_count or entry.inode >= ramfs.inode_count) return error.InvalidDirectory;
        if (state.inodes[entry.parent].i_links_count == 0 or
            state.inodes[entry.parent].i_type != .directory or
            state.inodes[entry.inode].i_links_count == 0) return error.InvalidDirectory;
        for (entry.name[0..entry.name_len]) |character| {
            if (character == 0 or character == '/') return error.InvalidName;
        }
    }
}

/// Serializes a complete RamFS state into a fixed-size VNV image.
pub fn encode(state: *const ramfs.State, out: []u8, sequence: u64) Error!usize {
    if (out.len < image_size) return error.BufferTooSmall;
    try validate(state);
    @memset(out[0..image_size], 0);
    put32(out, 0, magic);
    put16(out, 4, version);
    put16(out, 6, header_size);
    put32(out, 8, ramfs.block_size);
    put32(out, 12, ramfs.block_count);
    put32(out, 16, ramfs.inode_count);
    put32(out, 20, ramfs.dir_entry_count);
    put32(out, 24, ramfs.max_name_len);
    put64(out, 28, sequence);
    put64(out, 36, payload_size);

    @memcpy(out[header_size .. header_size + state.block_bitmap.len], &state.block_bitmap);
    for (state.inodes, 0..) |entry, index| {
        const at = inodeOffset(index);
        out[at] = @intFromEnum(entry.i_type);
        put16(out, at + 1, entry.i_permissions);
        put32(out, at + 3, entry.i_links_count);
        put64(out, at + 7, entry.i_size);
        put64(out, at + 15, entry.i_atime);
        put64(out, at + 23, entry.i_mtime);
        put64(out, at + 31, entry.i_ctime);
        for (entry.i_block, 0..) |block, block_index| put64(out, at + 39 + block_index * 8, block);
        put64(out, at + 135, entry.i_indirect);
        put64(out, at + 143, entry.i_double_indirect);
    }
    for (state.dir_entries, 0..) |entry, index| {
        const at = dirOffset(index);
        out[at] = @intFromBool(entry.used);
        put32(out, at + 1, entry.parent);
        put32(out, at + 5, entry.inode);
        out[at + 9] = entry.name_len;
        @memcpy(out[at + 10 .. at + 10 + ramfs.max_name_len], &entry.name);
    }
    @memcpy(out[memoryOffset() .. memoryOffset() + ramfs.total_size], &state.memory);
    put32(out, 44, checksum(out[header_size..image_size]));
    return image_size;
}

/// Decodes into a temporary state and commits only after every validation passes.
pub fn decode(input: []const u8, destination: *ramfs.State) Error!void {
    if (input.len != image_size) return error.InvalidSize;
    if (get32(input, 0) != magic) return error.InvalidMagic;
    if (get16(input, 4) != version) return error.UnsupportedVersion;
    if (get16(input, 6) != header_size or get32(input, 8) != ramfs.block_size or
        get32(input, 12) != ramfs.block_count or get32(input, 16) != ramfs.inode_count or
        get32(input, 20) != ramfs.dir_entry_count or get32(input, 24) != ramfs.max_name_len or
        get64(input, 36) != payload_size) return error.InvalidHeader;
    if (get32(input, 44) != checksum(input[header_size..image_size])) return error.ChecksumMismatch;

    var candidate: ramfs.State = undefined;
    @memcpy(&candidate.block_bitmap, input[header_size .. header_size + candidate.block_bitmap.len]);
    for (&candidate.inodes, 0..) |*entry, index| {
        const at = inodeOffset(index);
        entry.i_type = switch (input[at]) { 0 => .file, 1 => .directory, else => return error.InvalidInodeType };
        entry.i_permissions = get16(input, at + 1);
        entry.i_links_count = get32(input, at + 3);
        entry.i_size = get64(input, at + 7);
        entry.i_atime = get64(input, at + 15);
        entry.i_mtime = get64(input, at + 23);
        entry.i_ctime = get64(input, at + 31);
        for (&entry.i_block, 0..) |*block, block_index| block.* = get64(input, at + 39 + block_index * 8);
        entry.i_indirect = get64(input, at + 135);
        entry.i_double_indirect = get64(input, at + 143);
    }
    for (&candidate.dir_entries, 0..) |*entry, index| {
        const at = dirOffset(index);
        entry.used = input[at] != 0;
        if (input[at] > 1) return error.InvalidDirectory;
        entry.parent = get32(input, at + 1);
        entry.inode = get32(input, at + 5);
        entry.name_len = input[at + 9];
        @memcpy(&entry.name, input[at + 10 .. at + 10 + ramfs.max_name_len]);
    }
    @memcpy(&candidate.memory, input[memoryOffset() .. memoryOffset() + ramfs.total_size]);
    try validate(&candidate);
    destination.* = candidate;
}

test "VNV round trip is deterministic and preserves RamFS state" {
    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    const root = try ramfs.createDirectoryFor(&state, ramfs.root_inode, "apps");
    const file = try ramfs.createFileFor(&state, root, "hello");
    try ramfs.writeFileFor(&state, file, "persistent");
    var first: [image_size]u8 = undefined;
    var second: [image_size]u8 = undefined;
    _ = try encode(&state, &first, 7);
    _ = try encode(&state, &second, 7);
    try std.testing.expectEqualSlices(u8, &first, &second);
    var restored: ramfs.State = undefined;
    try decode(&first, &restored);
    var buffer: [16]u8 = undefined;
    const count = try ramfs.readFileFor(&restored, file, &buffer);
    try std.testing.expectEqualStrings("persistent", buffer[0..count]);
}

test "VNV rejects corruption without modifying destination" {
    var source: ramfs.State = undefined;
    ramfs.initState(&source);
    var image: [image_size]u8 = undefined;
    _ = try encode(&source, &image, 1);
    var destination: ramfs.State = undefined;
    @memset(destination.memory[0..], 0xA5);
    const before = destination.memory;
    image[header_size + 3] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&image, &destination));
    try std.testing.expectEqualSlices(u8, &before, &destination.memory);
}
