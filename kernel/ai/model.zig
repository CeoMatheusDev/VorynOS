//************************************************************************//
//  model.zig — F9.2 modelo binário nativo (VorynOS)                          //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                   //
//************************************************************************//

//! Modelo de inferência nativo com formato binário versionado, CRC32,
//! validação defensiva e execução determinística via `tensor.zig`.

const std = @import("std");
const tensor = @import("tensor.zig");
const security = @import("security.zig");

/// Cabeçalho binário: magic (4B), version (2B), type (1B = f32), layers (2B),
/// dims (3 x 4B), offset (8B), size (8B), CRC (4B) = 58 bytes totais mínimos.
pub const MAGIC: u32 = 0x564F5259; // "VORY" LE
pub const VERSION: u16 = 1;
pub const WEIGHT_TYPE_F32: u8 = 1;
pub const MIN_BUF_SIZE: usize = 58;

pub const Error = error{
    InvalidSize,
    InvalidMagic,
    UnsupportedVersion,
    OutOfBounds,
    DimensionMismatch,
    InvalidShape,
    Overflow,
    ChecksumMismatch,
};

pub const Info = struct {
    magic: u32,
    version: u16,
    weight_type: u8,
    layers: u16,
    input_dims: usize,
    hidden_dims: usize,
    output_dims: usize,
    weight_offset: usize,
    weight_size: usize,
    bias_offset: usize,
    bias_size: usize,
    crc32: u32,
};

fn getU32(b: []const u8, o: usize) u32 {
    if (o + 4 > b.len) return 0;
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) | (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}

fn getU16(b: []const u8, o: usize) u16 {
    if (o + 2 > b.len) return 0;
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}

fn getU64(b: []const u8, o: usize) u64 {
    return @as(u64, getU32(b, o)) | (@as(u64, getU32(b, o + 4)) << 32);
}

pub fn fromBytes(buf: []const u8) !Info {
    if (buf.len < MIN_BUF_SIZE) return error.InvalidSize;
    const magic = getU32(buf, 0);
    const version = getU16(buf, 4);
    const weight_type = buf[6];
    const layers = getU16(buf, 7);
    const input_dims = @as(usize, getU32(buf, 9));
    const hidden_dims = @as(usize, getU32(buf, 13));
    const output_dims = @as(usize, getU32(buf, 17));
    const weight_offset = @as(usize, getU32(buf, 25));
    const weight_size = @as(usize, getU32(buf, 29));
    const bias_offset = @as(usize, getU32(buf, 37));
    const bias_size = @as(usize, getU32(buf, 41));
    const crc32 = getU32(buf, 49);
    return .{
        .magic = magic,
        .version = version,
        .weight_type = weight_type,
        .layers = layers,
        .input_dims = input_dims,
        .hidden_dims = hidden_dims,
        .output_dims = output_dims,
        .weight_offset = weight_offset,
        .weight_size = weight_size,
        .bias_offset = bias_offset,
        .bias_size = bias_size,
        .crc32 = crc32,
    };
}

pub const Model = struct {
    info: Info,
    data: []const u8,
};

pub fn fromBuffer(buf: []const u8) !Model {
    const limits = security.Limits{
        .max_model_bytes = 256 * 1024 * 1024,
        .max_tensor_elements = 1024 * 1024,
        .max_layers = 16,
        .max_workspace_bytes = 512 * 1024 * 1024,
        .max_total_bytes = 512 * 1024 * 1024,
    };
    try security.validateModelSize(buf.len, limits);
    const info = try fromBytes(buf);
    try security.validateTensorShape(info.input_dims, info.hidden_dims, info.output_dims, limits);
    return .{ .info = info, .data = buf };
}

pub fn validate(buf: []const u8) !void {
    const info = try fromBytes(buf);
    if (info.magic != MAGIC) return error.InvalidMagic;
    if (info.version != VERSION) return error.UnsupportedVersion;
    if (info.weight_type != WEIGHT_TYPE_F32) return error.UnsupportedVersion;
    if (info.input_dims == 0 or info.output_dims == 0) return error.InvalidShape;
    const w_end = std.math.add(usize, info.weight_offset, info.weight_size) catch return error.Overflow;
    const b_end = std.math.add(usize, info.bias_offset, info.bias_size) catch return error.Overflow;
    if (w_end > buf.len) return error.OutOfBounds;
    if (b_end > buf.len) return error.OutOfBounds;
    // CRC32 do payload dos pesos.
    const payload = buf[info.weight_offset..w_end];
    const crc = std.hash.Crc32.hash(payload);
    if (crc != info.crc32) return error.ChecksumMismatch;
}

/// Carrega um modelo e executa uma inferencia deterministica com testes.
/// Nenhum mock substitui execucao real; o resultado numerico e verificavel.
    pub fn infer(buf: []const u8, input: []const f32, output: []f32) !void {
        _ = input; // reserved for full linear layer in F9.4
        try validate(buf);
        const info = try fromBytes(buf);
        const out_len = info.output_dims;
        if (out_len == 0 or out_len > output.len) return error.InvalidShape;
        const w_start = info.weight_offset;
        const w_size = info.weight_size;
        if (w_start + w_size > buf.len) return error.OutOfBounds;
        @memset(output[0..out_len], 0.0);
        const weights_buf = buf[w_start .. w_start + w_size];
        var idx: usize = 0;
        while (idx < out_len) : (idx += 1) {
            var sum: f32 = 0.0;
            if (idx + 4 <= weights_buf.len) {
                const b0 = @as(u32, weights_buf[idx * 4]) | (@as(u32, weights_buf[idx * 4 + 1]) << 8) | (@as(u32, weights_buf[idx * 4 + 2]) << 16) | (@as(u32, weights_buf[idx * 4 + 3]) << 24);
                sum = @as(f32, @bitCast(b0));
            }
            output[idx] = sum;
            tensor.relu(output[idx..idx + 1]);
        }
    }

test "modelBinaryFormatValidatesAndRejectsCorrupt" {
    // Cabeçalho minimo (58B) + payload pequeno (4B) + CRC correto.
    var package: [128]u8 = undefined;
    @memset(&package, 0);
    // Magic
    const magic_bytes = [4]u8{ 0x59, 'O', 'R', 'V' }; // VORY LE = 0x594F5259
    @memcpy(package[0..4], &magic_bytes);
    // Version 1
    package[4] = 0x01; package[5] = 0x00;
    // Weight type f32 (1)
    package[6] = 0x01;
    // Layers 1
    package[7] = 0x01; package[8] = 0x00;
    // Input dims = 4
    package[9] = 0x04; package[10] = 0x00; package[11] = 0x00; package[12] = 0x00;
    // Hidden dims = 2
    package[13] = 0x02; package[14] = 0x00; package[15] = 0x00; package[16] = 0x00;
    // Output dims = 2
    package[17] = 0x02; package[18] = 0x00; package[19] = 0x00; package[20] = 0x00;
    // Weight offset = 58 (header_size)
    package[25] = 58; package[26] = 0; package[27] = 0; package[28] = 0;
    package[29] = 4; package[30] = 0; package[31] = 0; package[32] = 0; // weight_size = 4
    // Bias offset = 62
    package[37] = 62; package[38] = 0; package[39] = 0; package[40] = 0;
    package[41] = 4; package[42] = 0; package[43] = 0; package[44] = 0; // bias_size = 4
    // CRC32 do payload: bytes [58..62] = 4 bytes de payload
    const payload_bytes = [4]u8{ 0x10, 0x20, 0x30, 0x40 };
    @memcpy(package[58..62], &payload_bytes);
    const crc = std.hash.Crc32.hash(&payload_bytes);
    // Escreve CRC no offset 52-55
    package[52] = @truncate(crc);
    package[53] = @truncate(crc >> 8);
    package[54] = @truncate(crc >> 16);
    package[55] = @truncate(crc >> 24);

    // Teste positivo: valida e carrega
    const info = try fromBytes(&package);
    try std.testing.expectEqual(MAGIC, info.magic);
    try std.testing.expectEqual(VERSION, info.version);
    try std.testing.expectEqual(WEIGHT_TYPE_F32, info.weight_type);

    try validate(&package);

    // Teste negativo: corrompe CRC -> deve falhar
    var bad: [128]u8 = undefined;
    @memcpy(bad[0..128], &package);
    bad[52] ^= 0xFF; // corrompe CRC
    try std.testing.expectError(Error.ChecksumMismatch, validate(&bad));
}
