//************************************************************************//
//  vex.zig                                                               //
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

//! Formato VEX (Voryn EXecutable): o container nativo de executáveis.
//!
//! Um arquivo VEX é um cabeçalho de manifest que envolve uma imagem ELF64
//! (`payload`). O carregador do kernel detecta o magic, valida o cabeçalho,
//! o CRC e o manifest de capacidades, e planeja o ELF interno normalmente.
//! O ELF continua sendo o formato de máquina; o VEX adiciona a camada de
//! metadados (versão, integridade, manifest de capacidades) sem alterar o
//! materializador.
//!
//! O formato é explicitamente little-endian e nunca depende do layout de
//! structs Zig (mesma regra do VNV e do VPK). A estrutura:
//!
//! ```text
//! +------------------+  offset 0
//! | cabeçalho (64 B) |  magic, versão, geometria, CRC do payload
//! +------------------+  offset 64 (= payload_offset)
//! | payload (ELF64)  |  a imagem executável
//! +------------------+  manifest_offset (opcional)
//! | manifest         |  registros {kind, rights} das capacidades
//! +------------------+
//! ```

const std = @import("std");

pub const magic: u32 = 0x3158_4556; // "VEX1" em little endian.
pub const version: u16 = 1;
pub const header_size: usize = 64;
pub const max_manifest_entries: usize = 16;

/// Tipos de capacidade declarados no manifest, espelhando os kinds do
/// kernel (`kernel/security/capability.zig`): canal, processo, display e
/// entrada. Valores novos exigem a atualização dos dois lados.
pub const CapabilityKind = enum(u32) {
    channel = 0,
    process = 1,
    display = 2,
    input = 3,
};

/// Uma capacidade declarada pelo executável.
pub const Capability = struct {
    kind: CapabilityKind,
    rights: u32,
};

pub const Error = error{
    /// O buffer de saída é pequeno demais para o VEX.
    BufferTooSmall,
    /// O tamanho do buffer não corresponde à geometria declarada.
    InvalidSize,
    /// Os bytes não começam com o magic "VEX1".
    NotVex,
    /// O magic confere, mas o valor é inválido.
    InvalidMagic,
    /// A versão do formato não é suportada.
    UnsupportedVersion,
    /// A geometria do cabeçalho é inconsistente.
    InvalidHeader,
    /// O CRC32 do payload não confere.
    ChecksumMismatch,
    /// O manifest é malformado (bounds, tamanho, sobreposição).
    InvalidManifest,
    /// O manifest declara um kind de capacidade desconhecido.
    UnknownCapabilityKind,
    /// Uma soma de tamanhos estourou.
    Overflow,
};

/// Resumo validado de um arquivo VEX.
pub const Info = struct {
    payload_size: usize,
    manifest_count: usize,
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

/// Tamanho exato de um arquivo VEX com `payload_len` bytes e um manifest
/// de `manifest_count` entradas.
pub fn packedSize(payload_len: usize, manifest_count: usize) Error!usize {
    if (manifest_count > max_manifest_entries) return error.InvalidManifest;
    const manifest_bytes = @as(usize, manifest_count) * 8;
    const total = std.math.add(usize, std.math.add(usize, header_size, payload_len) catch return error.Overflow, manifest_bytes) catch return error.Overflow;
    if (total > std.math.maxInt(usize)) return error.Overflow;
    return total;
}

/// Empacota a imagem ELF e o manifest em um arquivo VEX determinístico.
pub fn wrap(payload: []const u8, manifest: []const Capability, out: []u8) Error!usize {
    const total = try packedSize(payload.len, manifest.len);
    if (out.len < total) return error.BufferTooSmall;
    @memset(out[0..total], 0);

    const manifest_offset: u64 = if (manifest.len == 0) 0 else @as(u64, header_size) + payload.len;

    put32(out, 0, magic);
    put16(out, 4, version);
    put16(out, 6, header_size);
    put32(out, 8, 0); // flags reservados
    put64(out, 12, 0); // entry_hint reservado: a entrada do ELF vence
    put64(out, 20, header_size);
    put64(out, 28, payload.len);
    put64(out, 36, manifest_offset);
    put64(out, 44, manifest.len * 8);
    put32(out, 52, std.hash.Crc32.hash(payload));

    @memcpy(out[header_size .. header_size + payload.len], payload);
    for (manifest, 0..) |entry, index| {
        const at = manifest_offset + @as(u64, index) * 8;
        // Zig 0.17.0: @intFromEnum foi renomeado para @backingInt.
        put32(out, @intCast(at), @backingInt(entry.kind));
        put32(out, @intCast(at + 4), entry.rights);
    }
    return total;
}

/// Valida a estrutura completa de um arquivo VEX.
pub fn validate(bytes: []const u8) Error!Info {
    if (bytes.len < header_size) return error.InvalidSize;
    if (get32(bytes, 0) != magic) return error.InvalidMagic;
    if (get16(bytes, 4) != version) return error.UnsupportedVersion;
    if (get16(bytes, 6) != header_size) return error.InvalidHeader;

    const payload_offset = get64(bytes, 20);
    const payload_size = get64(bytes, 28);
    const manifest_offset = get64(bytes, 36);
    const manifest_size = get64(bytes, 44);

    if (payload_offset != header_size) return error.InvalidHeader;
    const payload_end = std.math.add(u64, payload_offset, payload_size) catch
        return error.InvalidHeader;
    if (payload_end != bytes.len and manifest_offset == 0) return error.InvalidHeader;
    if (payload_end > bytes.len) return error.InvalidSize;

    if (manifest_offset == 0) {
        if (manifest_size != 0) return error.InvalidHeader;
        if (payload_end != bytes.len) return error.InvalidHeader;
    } else {
        if (manifest_offset != payload_end) return error.InvalidHeader;
        if (manifest_size % 8 != 0) return error.InvalidManifest;
        const manifest_end = std.math.add(u64, manifest_offset, manifest_size) catch
            return error.InvalidHeader;
        if (manifest_end != bytes.len) return error.InvalidSize;
        if (manifest_size / 8 > max_manifest_entries) return error.InvalidManifest;
        var index: usize = 0;
        while (index < manifest_size / 8) : (index += 1) {
            const kind_value = get32(bytes, @intCast(manifest_offset + index * 8));
            // O tipo de backing de CapabilityKind é u32; a comparação
            // direta com o valor lido continua válida.
            if (kind_value > @backingInt(CapabilityKind.input)) return error.UnknownCapabilityKind;
        }
    }

    if (get32(bytes, 52) != std.hash.Crc32.hash(bytes[payload_offset..payload_end]))
        return error.ChecksumMismatch;

    return .{
        .payload_size = @intCast(payload_size),
        .manifest_count = if (manifest_offset == 0) 0 else @intCast(manifest_size / 8),
    };
}

/// Devolve a imagem ELF interna de um arquivo VEX.
///
/// Retorna `error.NotVex` quando os bytes não começam com o magic: o
/// chamador pode então tratar o arquivo como ELF puro. Para um VEX válido,
/// a fatia devolvida aponta para dentro do buffer do chamador.
pub fn unwrap(bytes: []const u8) Error![]const u8 {
    if (bytes.len < 4) return error.NotVex;
    if (get32(bytes, 0) != magic) return error.NotVex;
    const info = try validate(bytes);
    return bytes[header_size .. header_size + info.payload_size];
}

/// Copia o manifest validado para o vetor do chamador e devolve a contagem.
pub fn manifestList(bytes: []const u8, out: *[max_manifest_entries]Capability) Error!usize {
    const info = try validate(bytes);
    if (info.manifest_count == 0) return 0;
    const manifest_offset = get64(bytes, 36);
    var index: usize = 0;
    while (index < info.manifest_count) : (index += 1) {
        const at = manifest_offset + @as(u64, index) * 8;
        out[index] = .{
            // Zig 0.17.0: @enumFromInt foi renomeado para @fromBackingInt.
            .kind = @fromBackingInt(get32(bytes, @intCast(at))),
            .rights = get32(bytes, @intCast(at + 4)),
        };
    }
    return info.manifest_count;
}

const testing = std.testing;

const sample_payload = [_]u8{ 0x7f, 'E', 'L', 'F', 0x02, 0x01, 0x01, 0x00, 0x90, 0x90, 0x90 };
const sample_manifest = [_]Capability{
    .{ .kind = .display, .rights = 8 },
    .{ .kind = .input, .rights = 16 },
};

test "wrap and unwrap round trip preserves the payload and the manifest" {
    var package: [256]u8 = undefined;
    const wrapped = try wrap(&sample_payload, &sample_manifest, &package);
    const info = try validate(package[0..wrapped]);
    try testing.expectEqual(@as(usize, sample_payload.len), info.payload_size);
    try testing.expectEqual(@as(usize, 2), info.manifest_count);

    const payload = try unwrap(package[0..wrapped]);
    try testing.expectEqualSlices(u8, &sample_payload, payload);

    var manifest: [max_manifest_entries]Capability = undefined;
    const count = try manifestList(package[0..wrapped], &manifest);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(CapabilityKind.display, manifest[0].kind);
    try testing.expectEqual(@as(u32, 8), manifest[0].rights);
    try testing.expectEqual(CapabilityKind.input, manifest[1].kind);
    try testing.expectEqual(@as(u32, 16), manifest[1].rights);
}

test "wrap is deterministic and the size matches packedSize" {
    var first: [256]u8 = undefined;
    var second: [256]u8 = undefined;
    const first_len = try wrap(&sample_payload, &sample_manifest, &first);
    const second_len = try wrap(&sample_payload, &sample_manifest, &second);
    try testing.expectEqual(first_len, second_len);
    try testing.expectEqualSlices(u8, first[0..first_len], second[0..second_len]);
    try testing.expectEqual(first_len, try packedSize(sample_payload.len, sample_manifest.len));
}

test "a VEX without a manifest is valid and unwraps" {
    var package: [256]u8 = undefined;
    const wrapped = try wrap(&sample_payload, &.{}, &package);
    const info = try validate(package[0..wrapped]);
    try testing.expectEqual(@as(usize, 0), info.manifest_count);
    const payload = try unwrap(package[0..wrapped]);
    try testing.expectEqualSlices(u8, &sample_payload, payload);
}

test "raw ELF bytes are reported as NotVex" {
    try testing.expectError(error.NotVex, unwrap(&sample_payload));
    try testing.expectError(error.NotVex, unwrap(""));
    var header_only: [64]u8 = @splat(0);
    try testing.expectError(error.NotVex, unwrap(&header_only));
}

test "corruption and truncation are rejected" {
    var package: [256]u8 = undefined;
    const wrapped = try wrap(&sample_payload, &sample_manifest, &package);
    const bytes = package[0..wrapped];

    try testing.expectError(error.InvalidSize, validate(bytes[0 .. wrapped - 1]));

    var bad_magic: [256]u8 = undefined;
    @memcpy(bad_magic[0..wrapped], bytes);
    bad_magic[0] = 0;
    try testing.expectError(error.InvalidMagic, validate(bad_magic[0..wrapped]));

    var bad_version: [256]u8 = undefined;
    @memcpy(bad_version[0..wrapped], bytes);
    bad_version[4] = 2;
    try testing.expectError(error.UnsupportedVersion, validate(bad_version[0..wrapped]));

    // Corrupção de um byte do payload: o CRC acusa.
    var corrupted: [256]u8 = undefined;
    @memcpy(corrupted[0..wrapped], bytes);
    corrupted[header_size + 3] ^= 0xFF;
    try testing.expectError(error.ChecksumMismatch, validate(corrupted[0..wrapped]));
    try testing.expectError(error.ChecksumMismatch, unwrap(corrupted[0..wrapped]));
}

test "a malformed or oversized manifest is rejected" {
    var package: [256]u8 = undefined;
    const wrapped = try wrap(&sample_payload, &sample_manifest, &package);
    const bytes = package[0..wrapped];

    // Manifest com kind desconhecido.
    var bad_kind: [256]u8 = undefined;
    @memcpy(bad_kind[0..wrapped], bytes);
    const manifest_offset = header_size + sample_payload.len;
    bad_kind[manifest_offset] = 99;
    try testing.expectError(error.UnknownCapabilityKind, validate(bad_kind[0..wrapped]));

    // Manifest que não começa logo após o payload.
    var bad_offset: [256]u8 = undefined;
    @memcpy(bad_offset[0..wrapped], bytes);
    bad_offset[36] = 1;
    try testing.expectError(error.InvalidHeader, validate(bad_offset[0..wrapped]));

    try testing.expectError(error.InvalidManifest, packedSize(0, max_manifest_entries + 1));
}

test "an empty payload wraps and unwraps structurally" {
    var package: [128]u8 = undefined;
    const wrapped = try wrap("", &.{}, &package);
    // VEX com payload vazio é estruturalmente válido; o planejador ELF é
    // quem recusa a imagem vazia (EmptyImage).
    _ = try validate(package[0..wrapped]);
    const payload = try unwrap(package[0..wrapped]);
    try testing.expectEqual(@as(usize, 0), payload.len);
}
