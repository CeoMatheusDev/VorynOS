//************************************************************************//
//  vnv.zig                                                               //
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
            if (entry.i_size != 0 or entry.i_indirect != 0 or entry.i_double_indirect != 0) return error.InvalidInode;
            for (entry.i_block) |block| if (block != 0) return error.InvalidInode;
            continue;
        }
        if (index == ramfs.root_inode and entry.i_type != .directory) return error.InvalidInode;
        if (entry.i_type != .file and entry.i_type != .directory) return error.InvalidInodeType;
        if (entry.i_size > ramfs.max_file_size) return error.InvalidInode;
        // O RamFS atual implementa somente a tabela indireta única; o
        // ponteiro duplo tem de estar zerado.
        if (entry.i_double_indirect != 0) return error.InvalidBlock;
        if (entry.i_type == .directory and entry.i_indirect != 0) return error.InvalidBlock;
        const blocks: usize = (@as(usize, @intCast(entry.i_size)) + ramfs.block_size - 1) / ramfs.block_size;
        if (blocks > ramfs.max_blocks) return error.InvalidInode;
        for (entry.i_block, 0..) |block, block_index| {
            if (block_index >= blocks) {
                if (block != 0) return error.InvalidBlock;
                continue;
            }
            if (block == 0 or block >= ramfs.block_count) return error.InvalidBlock;
            const bit = @as(u8, 1) << @intCast(block % 8);
            expected_bitmap[block / 8] |= bit;
        }
        if (blocks > ramfs.direct_blocks) {
            // A tabela indireta existe, está marcada no bitmap e cada
            // entrada usada pelo tamanho aponta para um bloco válido e
            // marcado; as entradas além do tamanho têm de estar zeradas.
            if (entry.i_indirect == 0 or entry.i_indirect >= ramfs.block_count) return error.InvalidBlock;
            const table_bit = @as(u8, 1) << @intCast(entry.i_indirect % 8);
            expected_bitmap[entry.i_indirect / 8] |= table_bit;
            const table_index: usize = @intCast(entry.i_indirect);
            const table = std.mem.bytesAsSlice(u64, state.memory[table_index * ramfs.block_size ..][0..ramfs.block_size]);
            const indirect_used = blocks - ramfs.direct_blocks;
            for (table, 0..) |entry_ptr, slot| {
                if (slot >= indirect_used) {
                    if (entry_ptr != 0) return error.InvalidBlock;
                    continue;
                }
                if (entry_ptr == 0 or entry_ptr >= ramfs.block_count) return error.InvalidBlock;
                const entry_bit = @as(u8, 1) << @intCast(entry_ptr % 8);
                expected_bitmap[entry_ptr / 8] |= entry_bit;
            }
        } else if (entry.i_indirect != 0) {
            return error.InvalidBlock;
        }
    }
    if (!std.mem.eql(u8, &expected_bitmap, &state.block_bitmap)) return error.BitmapMismatch;

    for (state.dir_entries, 0..) |entry, entry_index| {
        if (!entry.used) {
            if (entry.parent != 0 or entry.inode != 0 or entry.name_len != 0 or
                !std.mem.allEqual(u8, &entry.name, 0)) return error.InvalidDirectory;
            continue;
        }
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

/// Decodes into a caller-supplied scratch state and commits only after
/// every validation passes.
///
/// The scratch state is explicit because `ramfs.State` is ~1 MiB: a local
/// of that size overflows the 16 KiB boot stack of the kernel. The caller
/// owns the scratch (a static buffer in the kernel, a local on the host)
/// and the destination is only touched after `validate` succeeds.
pub fn decode(input: []const u8, destination: *ramfs.State, scratch: *ramfs.State) Error!void {
    if (input.len != image_size) return error.InvalidSize;
    if (get32(input, 0) != magic) return error.InvalidMagic;
    if (get16(input, 4) != version) return error.UnsupportedVersion;
    if (get16(input, 6) != header_size or get32(input, 8) != ramfs.block_size or
        get32(input, 12) != ramfs.block_count or get32(input, 16) != ramfs.inode_count or
        get32(input, 20) != ramfs.dir_entry_count or get32(input, 24) != ramfs.max_name_len or
        get64(input, 36) != payload_size) return error.InvalidHeader;
    if (get32(input, 44) != checksum(input[header_size..image_size])) return error.ChecksumMismatch;

    const candidate = scratch;
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
    try validate(candidate);
    // O commit usa @memcpy campo a campo, e não uma atribuição de struct:
    // em modo Debug o compilador copia uma struct de ~1 MiB através de um
    // temporário na pilha, e a pilha de boot do kernel tem só 16 KiB.
    @memcpy(destination.memory[0..], &candidate.memory);
    @memcpy(destination.block_bitmap[0..], &candidate.block_bitmap);
    @memcpy(destination.inodes[0..], &candidate.inodes);
    @memcpy(destination.dir_entries[0..], &candidate.dir_entries);
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
    var scratch: ramfs.State = undefined;
    try decode(&first, &restored, &scratch);
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
    var scratch: ramfs.State = undefined;
    try std.testing.expectError(error.ChecksumMismatch, decode(&image, &destination, &scratch));
    try std.testing.expectEqualSlices(u8, &before, &destination.memory);
}

test "VNV round trip preserves indirect blocks" {
    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    const root = try ramfs.createDirectoryFor(&state, ramfs.root_inode, "apps");
    const file = try ramfs.createFileFor(&state, root, "large.bin");
    // 14 blocos: 12 diretos + 2 via tabela indireta.
    const payload: [ramfs.direct_blocks * ramfs.block_size + 2 * ramfs.block_size]u8 = @splat(0x3c);
    try ramfs.writeFileFor(&state, file, &payload);

    var image: [image_size]u8 = undefined;
    _ = try encode(&state, &image, 9);

    var restored: ramfs.State = undefined;
    var scratch: ramfs.State = undefined;
    try decode(&image, &restored, &scratch);
    try std.testing.expectEqual(@as(u64, payload.len), restored.inodes[file].i_size);
    try std.testing.expect(restored.inodes[file].i_indirect != 0);
    var buffer: [payload.len]u8 = undefined;
    const count = try ramfs.readFileFor(&restored, file, &buffer);
    try std.testing.expectEqual(buffer.len, count);
    try std.testing.expectEqual(@as(u8, 0x3c), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x3c), buffer[ramfs.direct_blocks * ramfs.block_size]);
    try std.testing.expectEqual(@as(u8, 0x3c), buffer[buffer.len - 1]);
}

test "VNV validate rejects inconsistent indirect tables" {
    var state: ramfs.State = undefined;
    ramfs.initState(&state);
    const file = try ramfs.createFileFor(&state, ramfs.root_inode, "large");
    const payload: [ramfs.direct_blocks * ramfs.block_size + 1]u8 = @splat(0x11);
    try ramfs.writeFileFor(&state, file, &payload);

    var image: [image_size]u8 = undefined;
    _ = try encode(&state, &image, 1);

    // Entrada além do tamanho deixa de ser zero.
    const table_index: usize = @intCast(state.inodes[file].i_indirect);
    const table = std.mem.bytesAsSlice(u64, state.memory[table_index * ramfs.block_size ..][0..ramfs.block_size]);
    const original = table[1];
    table[1] = 1;
    try std.testing.expectError(error.InvalidBlock, encode(&state, &image, 1));
    table[1] = original;
    _ = try encode(&state, &image, 1);

    // Arquivo grande sem tabela indireta.
    const indirect = state.inodes[file].i_indirect;
    state.inodes[file].i_indirect = 0;
    try std.testing.expectError(error.InvalidBlock, encode(&state, &image, 1));
    state.inodes[file].i_indirect = indirect;
    _ = try encode(&state, &image, 1);
}
