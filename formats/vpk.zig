//************************************************************************//
//  vpk.zig                                                               //
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

//! Container VPK (Voryn Application Package): um arquivo único que embala
//! um executável e seus recursos com nomes, tipos e integridade por entrada.
//!
//! O formato é explícito little-endian e nunca depende do layout de structs
//! Zig (mesma regra do codec VNV). A estrutura é:
//!
//! ```text
//! +------------------+  offset 0
//! | cabeçalho (64 B) |  magic, versão, contagem, geometria, CRC do corpo
//! +------------------+  offset 64 (table_offset)
//! | registros (N*32) |  nome, tipo, offset, tamanho e CRC de cada entrada
//! | nomes            |  nomes das entradas, consecutivos
//! +------------------+  payload_offset = table_offset + table_size
//! | payload          |  bytes dos arquivos, consecutivos
//! +------------------+
//! ```
//!
//! O checksum do cabeçalho cobre o corpo inteiro (tabela + payload). Cada
//! entrada carrega o CRC32 dos seus próprios bytes, então `readEntry` prova
//! a integridade do arquivo individual, não só do pacote. O código é puro:
//! sem syscalls, sem alocação e sem I/O; o armazenamento fica com o VFSX.

const std = @import("std");

pub const magic: u32 = 0x5650_4B31; // "VPK1" em little endian.
pub const version: u16 = 1;
pub const header_size: usize = 64;
pub const entry_record_size: usize = 32;
pub const max_name_len: usize = 255;
pub const max_entries: usize = 4096;

/// Tipo de uma entrada do pacote.
pub const EntryKind = enum(u8) {
    executable = 0,
    data = 1,
    config = 2,
};

pub const Error = error{
    /// O buffer de saída é pequeno demais para o pacote.
    BufferTooSmall,
    /// O tamanho do buffer não corresponde à geometria declarada.
    InvalidSize,
    /// O magic não é "VPK1".
    InvalidMagic,
    /// A versão do formato não é suportada.
    UnsupportedVersion,
    /// A geometria do cabeçalho é inconsistente.
    InvalidHeader,
    /// Um nome é vazio, longo demais ou contém caractere inválido.
    InvalidName,
    /// Dois arquivos com o mesmo nome.
    DuplicateName,
    /// O tipo de uma entrada é desconhecido.
    InvalidKind,
    /// Um campo aponta para fora do pacote.
    OutOfBounds,
    /// O CRC do corpo ou de uma entrada não confere.
    ChecksumMismatch,
    /// A entrada pedida não existe.
    EntryNotFound,
    /// Uma soma de tamanhos estourou.
    Overflow,
};

/// Fonte de um arquivo na operação de empacotamento.
pub const FileSource = struct {
    name: []const u8,
    kind: EntryKind,
    bytes: []const u8,
};

/// Resumo validado de um pacote.
pub const Info = struct {
    entry_count: usize,
    payload_size: u64,
    total_size: usize,
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

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |character| {
        if (character == 0 or character == '/') return false;
    }
    return true;
}

/// Calcula o tamanho exato de um pacote com os arquivos dados.
pub fn packedSize(files: []const FileSource) Error!usize {
    if (files.len > max_entries) return error.Overflow;
    var names_total: u64 = 0;
    var payload_total: u64 = 0;
    for (files, 0..) |file, index| {
        if (!validName(file.name)) return error.InvalidName;
        for (files[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, file.name)) return error.DuplicateName;
        }
        names_total += file.name.len;
        payload_total += file.bytes.len;
    }
    const table_size = @as(u64, files.len) * entry_record_size + names_total;
    const payload_offset = @as(u64, header_size) + table_size;
    const total = payload_offset + payload_total;
    if (total > std.math.maxInt(usize)) return error.Overflow;
    return @intCast(total);
}

/// Empacota os arquivos em um pacote VPK determinístico.
pub fn pack(files: []const FileSource, out: []u8) Error!usize {
    const total = try packedSize(files);
    if (out.len < total) return error.BufferTooSmall;
    @memset(out[0..total], 0);

    const table_size: u64 = @as(u64, files.len) * entry_record_size + namesTotal(files);
    const payload_offset: u64 = @as(u64, header_size) + table_size;
    const payload_size: u64 = payloadTotal(files);

    put32(out, 0, magic);
    put16(out, 4, version);
    put16(out, 6, header_size);
    put32(out, 8, @intCast(files.len));
    put64(out, 12, header_size);
    put64(out, 20, table_size);
    put64(out, 28, payload_offset);
    put64(out, 36, payload_size);
    put64(out, 44, total);

    var names_cursor: usize = files.len * entry_record_size;
    var payload_cursor: u64 = 0;
    for (files, 0..) |file, index| {
        const at = header_size + index * entry_record_size;
        put64(out, at, names_cursor);
        put16(out, at + 8, @intCast(file.name.len));
        // Zig 0.17.0: @intFromEnum foi renomeado para @backingInt.
        out[at + 10] = @backingInt(file.kind);
        put64(out, at + 12, payload_cursor);
        put64(out, at + 20, file.bytes.len);
        put32(out, at + 28, std.hash.Crc32.hash(file.bytes));

        @memcpy(out[header_size + names_cursor ..][0..file.name.len], file.name);
        names_cursor += file.name.len;
        @memcpy(out[payload_offset + payload_cursor ..][0..file.bytes.len], file.bytes);
        payload_cursor += file.bytes.len;
    }

    put32(out, 52, checksumBody(out[0..total]));
    return total;
}

fn namesTotal(files: []const FileSource) u64 {
    var total: u64 = 0;
    for (files) |file| total += file.name.len;
    return total;
}

fn payloadTotal(files: []const FileSource) u64 {
    var total: u64 = 0;
    for (files) |file| total += file.bytes.len;
    return total;
}

fn checksumBody(body: []const u8) u32 {
    return std.hash.Crc32.hash(body[header_size..]);
}

/// Uma entrada decodificada, sem copiar o payload.
pub const Entry = struct {
    name: []const u8,
    kind: EntryKind,
    offset: u64,
    size: u64,
    crc32: u32,
};

fn entryName(bytes: []const u8, record: usize) []const u8 {
    const at = header_size + record * entry_record_size;
    const name_offset: usize = @intCast(get64(bytes, at));
    const name_len: usize = get16(bytes, at + 8);
    const table = bytes[header_size..];
    return table[name_offset .. name_offset + name_len];
}

fn entryAt(bytes: []const u8, index: usize) Error!Entry {
    const info = try validate(bytes);
    if (index >= info.entry_count) return error.EntryNotFound;
    const at = header_size + index * entry_record_size;
    const table = bytes[header_size..];
    const name_offset: usize = @intCast(get64(bytes, at));
    const name_len: usize = get16(bytes, at + 8);
    const kind_value = bytes[at + 10];
    const offset = get64(bytes, at + 12);
    const size = get64(bytes, at + 20);
    const crc = get32(bytes, at + 28);
    // Zig 0.17.0: @intFromEnum foi renomeado para @backingInt.
    if (kind_value > @backingInt(EntryKind.config)) return error.InvalidKind;
    return .{
        .name = table[name_offset .. name_offset + name_len],
        // Zig 0.17.0: @enumFromInt foi renomeado para @fromBackingInt.
        .kind = @fromBackingInt(kind_value),
        .offset = offset,
        .size = size,
        .crc32 = crc,
    };
}

/// Valida a estrutura completa do pacote, incluindo o CRC do corpo.
pub fn validate(bytes: []const u8) Error!Info {
    if (bytes.len < header_size) return error.InvalidSize;
    if (get32(bytes, 0) != magic) return error.InvalidMagic;
    if (get16(bytes, 4) != version) return error.UnsupportedVersion;
    if (get16(bytes, 6) != header_size) return error.InvalidHeader;

    const entry_count = get32(bytes, 8);
    const table_offset = get64(bytes, 12);
    const table_size = get64(bytes, 20);
    const payload_offset = get64(bytes, 28);
    const payload_size = get64(bytes, 36);
    const total = get64(bytes, 44);

    if (entry_count > max_entries) return error.InvalidHeader;
    if (table_offset != header_size) return error.InvalidHeader;
    if (table_size < @as(u64, entry_count) * entry_record_size) return error.InvalidHeader;
    if (payload_offset != table_offset + table_size) return error.InvalidHeader;
    if (total != payload_offset + payload_size) return error.InvalidHeader;
    if (total != bytes.len) return error.InvalidSize;
    if (total > std.math.maxInt(usize)) return error.InvalidHeader;
    if (get32(bytes, 52) != checksumBody(bytes)) return error.ChecksumMismatch;

    // A região de nomes começa logo após os registros, dentro da tabela.
    const names_start: u64 = @as(u64, entry_count) * entry_record_size;
    const names_end: u64 = table_size;
    if (names_start > names_end) return error.InvalidHeader;

    var previous_name: ?[]const u8 = null;
    var index: usize = 0;
    while (index < entry_count) : (index += 1) {
        const at = header_size + index * entry_record_size;
        const name_offset = get64(bytes, at);
        const name_len: usize = get16(bytes, at + 8);
        const kind_value = bytes[at + 10];
        const offset = get64(bytes, at + 12);
        const size = get64(bytes, at + 20);
        if (bytes[at + 11] != 0) return error.InvalidHeader;
        // Zig 0.17.0: @intFromEnum foi renomeado para @backingInt.
        if (kind_value > @backingInt(EntryKind.config)) return error.InvalidKind;
        if (name_offset < names_start or name_len > max_name_len or
            name_offset + name_len > names_end)
        {
            return error.OutOfBounds;
        }
        const name = entryName(bytes, index);
        if (!validName(name)) return error.InvalidName;
        if (previous_name) |previous| {
            if (std.mem.eql(u8, previous, name)) return error.DuplicateName;
        }
        previous_name = name;
        if (offset + size > payload_size) return error.OutOfBounds;
    }

    return .{
        .entry_count = entry_count,
        .payload_size = payload_size,
        .total_size = @intCast(total),
    };
}

/// Copia os bytes de uma entrada para `out` e confere o CRC da entrada.
pub fn readEntry(bytes: []const u8, index: usize, out: []u8) Error!usize {
    const entry = try entryAt(bytes, index);
    if (out.len < entry.size) return error.BufferTooSmall;
    const info = try validate(bytes);
    const start: usize = @intCast(info.total_size - info.payload_size + entry.offset);
    @memcpy(out[0..@intCast(entry.size)], bytes[start .. start + @as(usize, @intCast(entry.size))]);
    if (std.hash.Crc32.hash(out[0..@intCast(entry.size)]) != entry.crc32) return error.ChecksumMismatch;
    return @intCast(entry.size);
}

/// Localiza uma entrada pelo nome e copia os bytes.
pub fn readEntryByName(bytes: []const u8, name: []const u8, out: []u8) Error!usize {
    const info = try validate(bytes);
    var index: usize = 0;
    while (index < info.entry_count) : (index += 1) {
        const entry = try entryAt(bytes, index);
        if (std.mem.eql(u8, entry.name, name)) {
            if (out.len < entry.size) return error.BufferTooSmall;
            const start: usize = @intCast(info.total_size - info.payload_size + entry.offset);
            @memcpy(out[0..@intCast(entry.size)], bytes[start .. start + @as(usize, @intCast(entry.size))]);
            if (std.hash.Crc32.hash(out[0..@intCast(entry.size)]) != entry.crc32) return error.ChecksumMismatch;
            return @intCast(entry.size);
        }
    }
    return error.EntryNotFound;
}

const testing = std.testing;

const sample_files = [_]FileSource{
    .{ .name = "hello.txt", .kind = .data, .bytes = "VorynOS" },
    .{ .name = "manifest.vcfg", .kind = .config, .bytes = "app=hello\nexec=hello.vex\n" },
};

test "pack and read round trip preserves names, kinds and bytes" {
    var package: [256]u8 = undefined;
    const packed_len = try pack(&sample_files, &package);
    const info = try validate(package[0..packed_len]);
    try testing.expectEqual(@as(usize, 2), info.entry_count);

    var buffer: [64]u8 = undefined;
    const hello = try readEntryByName(package[0..packed_len], "hello.txt", &buffer);
    try testing.expectEqualStrings("VorynOS", buffer[0..hello]);
    const manifest = try readEntryByName(package[0..packed_len], "manifest.vcfg", &buffer);
    try testing.expectEqualStrings("app=hello\nexec=hello.vex\n", buffer[0..manifest]);

    const entry = try entryAt(package[0..packed_len], 0);
    try testing.expectEqualStrings("hello.txt", entry.name);
    try testing.expectEqual(EntryKind.data, entry.kind);
    try testing.expectEqual(@as(u64, 7), entry.size);
}

test "packing is deterministic and the size matches packedSize" {
    var first: [256]u8 = undefined;
    var second: [256]u8 = undefined;
    const first_len = try pack(&sample_files, &first);
    const second_len = try pack(&sample_files, &second);
    try testing.expectEqual(first_len, second_len);
    try testing.expectEqualSlices(u8, first[0..first_len], second[0..second_len]);
    try testing.expectEqual(first_len, try packedSize(&sample_files));
}

test "a truncated or corrupted package is rejected" {
    var package: [256]u8 = undefined;
    const packed_len = try pack(&sample_files, &package);
    const bytes = package[0..packed_len];

    try testing.expectError(error.InvalidSize, validate(bytes[0 .. packed_len - 1]));
    var corrupted: [256]u8 = undefined;
    @memcpy(corrupted[0..packed_len], bytes);
    corrupted[header_size + 4] ^= 1; // dentro do corpo (tabela)
    try testing.expectError(error.ChecksumMismatch, validate(corrupted[0..packed_len]));
}

test "unknown magic, version and geometry are rejected" {
    var package: [256]u8 = undefined;
    const packed_len = try pack(&sample_files, &package);
    const bytes = package[0..packed_len];

    var bad_magic: [256]u8 = undefined;
    @memcpy(bad_magic[0..packed_len], bytes);
    bad_magic[0] = 0;
    try testing.expectError(error.InvalidMagic, validate(bad_magic[0..packed_len]));

    var bad_version: [256]u8 = undefined;
    @memcpy(bad_version[0..packed_len], bytes);
    bad_version[4] = 2;
    try testing.expectError(error.UnsupportedVersion, validate(bad_version[0..packed_len]));

    var bad_offset: [256]u8 = undefined;
    @memcpy(bad_offset[0..packed_len], bytes);
    bad_offset[12] = 1; // table_offset != header_size
    try testing.expectError(error.InvalidHeader, validate(bad_offset[0..packed_len]));
}

test "entry payload corruption is caught by the per-entry CRC" {
    var package: [256]u8 = undefined;
    const packed_len = try pack(&sample_files, &package);
    var buffer: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 7), try readEntryByName(package[0..packed_len], "hello.txt", &buffer));

    // Corrompe um byte do payload e refaz o CRC do corpo para que a
    // validação estrutural passe; só o CRC da entrada acusa.
    package[header_size + 2 * entry_record_size + namesTotal(&sample_files)] ^= 0xFF;
    put32(package[0..packed_len], 52, checksumBody(package[0..packed_len]));
    try testing.expectError(error.ChecksumMismatch, readEntryByName(package[0..packed_len], "hello.txt", &buffer));
}

test "invalid names and duplicate names are rejected at pack time" {
    const bad_slash = [_]FileSource{.{ .name = "a/b", .kind = .data, .bytes = "x" }};
    var package: [128]u8 = undefined;
    try testing.expectError(error.InvalidName, pack(&bad_slash, &package));

    const bad_empty = [_]FileSource{.{ .name = "", .kind = .data, .bytes = "x" }};
    try testing.expectError(error.InvalidName, pack(&bad_empty, &package));

    const bad_nul = [_]FileSource{.{ .name = "a\x00b", .kind = .data, .bytes = "x" }};
    try testing.expectError(error.InvalidName, pack(&bad_nul, &package));

    const duplicate = [_]FileSource{
        .{ .name = "same", .kind = .data, .bytes = "a" },
        .{ .name = "same", .kind = .data, .bytes = "b" },
    };
    try testing.expectError(error.DuplicateName, pack(&duplicate, &package));
}

test "readEntry rejects a missing entry and an undersized output" {
    var package: [256]u8 = undefined;
    const packed_len = try pack(&sample_files, &package);
    var small: [4]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, readEntryByName(package[0..packed_len], "hello.txt", &small));
    try testing.expectError(error.EntryNotFound, readEntryByName(package[0..packed_len], "missing", &small));
    try testing.expectError(error.EntryNotFound, readEntry(package[0..packed_len], 2, &small));
}

test "an empty package is valid" {
    var package: [128]u8 = undefined;
    const packed_len = try pack(&[_]FileSource{}, &package);
    const info = try validate(package[0..packed_len]);
    try testing.expectEqual(@as(usize, 0), info.entry_count);
    try testing.expectEqual(@as(u64, 0), info.payload_size);
}

test "an oversized package request fails cleanly" {
    var many: [max_entries + 1]FileSource = undefined;
    for (&many) |*file| file.* = .{ .name = "f", .kind = .data, .bytes = "x" };
    try testing.expectError(error.Overflow, packedSize(&many));
}
