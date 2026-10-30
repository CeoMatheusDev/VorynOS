//************************************************************************//
//  embedded.zig                                                          //
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

//! The model image that the kernel embeds.
//!
//! The image is built at **compile time** in the binary format that
//! `model.zig` validates (magic, version, geometry, offsets, CRC32 of the
//! weights). Nothing is read from disk, from the firmware or from the
//! network: the bytes are part of the kernel image, and the CRC is computed
//! by the compiler over the same bytes that the validator reads.
//!
//! The weights and the bias are powers of two and small integers, so every
//! product and every sum is exactly representable in `f32`. The result is
//! therefore bit exact on any x86_64 machine, and a difference is a defect
//! and not a rounding artefact.
//!
//! The model is one dense layer with a ReLU activation:
//!
//!     y[j] = relu( sum_{k} w[j][k] * x[k] + b[j] )
//!
//! With `x = [1, 2, 3, 4]` the expected output is `[2.125, 5.25, 4]`, the
//! value that `shared/ai.zig` publishes in the contract.

const std = @import("std");

const voryn = @import("voryn_shared");
const contract = voryn.ai;
const model = @import("model.zig");

/// The weights of the layer, one row per output feature.
pub const weights = [contract.output_dims][contract.input_dims]f32{
    .{ 0.5, 0.25, 0.125, 0.0625 },
    .{ 2.0, 0.0, 1.0, 0.0 },
    .{ 0.0, 1.0, 0.0, 0.5 },
};

/// The bias of the layer, one value per output feature.
pub const bias = [contract.output_dims]f32{ 0.5, 0.25, 0.0 };

/// Offset of the weights inside the image.
const weight_offset: usize = 64;

/// Offset of the bias inside the image.
const bias_offset: usize = weight_offset + contract.input_dims * contract.output_dims * 4;

/// Number of bytes of the weight section.
const weight_size: usize = contract.input_dims * contract.output_dims * 4;

/// Number of bytes of the bias section.
const bias_size: usize = contract.output_dims * 4;

/// Total number of bytes of the image.
pub const image_len: usize = bias_offset + bias_size;

/// The image that the kernel validates and runs.
pub const image: [image_len]u8 = build();

fn putU32(buffer: *[image_len]u8, offset: usize, value: u32) void {
    buffer[offset] = @truncate(value);
    buffer[offset + 1] = @truncate(value >> 8);
    buffer[offset + 2] = @truncate(value >> 16);
    buffer[offset + 3] = @truncate(value >> 24);
}

fn putU16(buffer: *[image_len]u8, offset: usize, value: u16) void {
    buffer[offset] = @truncate(value);
    buffer[offset + 1] = @truncate(value >> 8);
}

fn putF32(buffer: *[image_len]u8, offset: usize, value: f32) void {
    putU32(buffer, offset, @bitCast(value));
}

/// Builds the image with the header of `model.zig`.
///
/// The offsets match the ones that `model.fromBytes` reads, and the CRC is
/// the one that `model.validate` recomputes over the weight section.
fn build() [image_len]u8 {
    var buffer: [image_len]u8 = @splat(0);

    putU32(&buffer, 0, model.MAGIC);
    putU16(&buffer, 4, model.VERSION);
    buffer[6] = model.WEIGHT_TYPE_F32;
    putU16(&buffer, 7, 1);
    putU32(&buffer, 9, @intCast(contract.input_dims));
    putU32(&buffer, 13, @intCast(contract.input_dims));
    putU32(&buffer, 17, @intCast(contract.output_dims));

    putU32(&buffer, 25, @intCast(weight_offset));
    putU32(&buffer, 29, @intCast(weight_size));
    putU32(&buffer, 37, @intCast(bias_offset));
    putU32(&buffer, 41, @intCast(bias_size));

    for (weights, 0..) |row, output| {
        for (row, 0..) |value, input| {
            putF32(&buffer, weight_offset + (output * contract.input_dims + input) * 4, value);
        }
        putF32(&buffer, bias_offset + output * 4, bias[output]);
    }

    const crc = std.hash.Crc32.hash(buffer[weight_offset..bias_offset]);
    putU32(&buffer, 52, crc);

    return buffer;
}

test "the embedded image validates against the model format" {
    try model.validate(&image);
    const info = try model.fromBytes(&image);
    try std.testing.expectEqual(model.MAGIC, info.magic);
    try std.testing.expectEqual(contract.input_dims, info.input_dims);
    try std.testing.expectEqual(contract.output_dims, info.output_dims);
    try std.testing.expectEqual(weight_offset, info.weight_offset);
    try std.testing.expectEqual(weight_size, info.weight_size);
    try std.testing.expectEqual(bias_offset, info.bias_offset);
    try std.testing.expectEqual(bias_size, info.bias_size);
}

test "the embedded image produces the exact output of the contract" {
    var input: [contract.input_dims]f32 = contract.sample_input;
    var output: [contract.output_dims]f32 = @splat(0.0);

    try model.infer(&image, &input, &output);

    try std.testing.expect(contract.matchesExpected(&output));
    try std.testing.expectEqual(contract.expectedChecksum(), contract.checksumOf(&output));
}

test "the inference is deterministic across repeated runs" {
    var input: [contract.input_dims]f32 = contract.sample_input;
    var first: [contract.output_dims]f32 = @splat(0.0);
    var second: [contract.output_dims]f32 = @splat(0.0);

    try model.infer(&image, &input, &first);
    try model.infer(&image, &input, &second);

    try std.testing.expectEqualSlices(f32, &first, &second);
}

test "a corrupted image is refused before the inference" {
    var corrupted: [image_len]u8 = image;
    corrupted[weight_offset] ^= 0xff;

    var input: [contract.input_dims]f32 = contract.sample_input;
    var output: [contract.output_dims]f32 = @splat(0.0);

    try std.testing.expectError(model.Error.ChecksumMismatch, model.infer(&corrupted, &input, &output));
}
