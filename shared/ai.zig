//************************************************************************//
//  ai.zig                                                                //
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

//! Contract of the inference call of the VorynOS system call interface
//! (number 24, `ai_infer`).
//!
//! The kernel embeds **one** deterministic model, and the contract fixes its
//! geometry here so that a program can size its buffers without asking the
//! kernel. The geometry is part of the ABI: a program compiled against this
//! version sends 4 `f32` values and receives 3 `f32` values.
//!
//! The values are chosen so that every intermediate result is exactly
//! representable in `f32` (powers of two and small integers), and therefore
//! the inference is **bit exact** across the kernel, the application and the
//! host tests. A program that receives different bits has a real defect.
//!
//! The capability that authorizes the call has kind 4 and the right
//! `execute`. The kernel is the root authority: a process that does not hold
//! the capability is refused with error 10 before any buffer is touched.

const std = @import("std");

/// The name of the call, for the diagnostics of the kernel.
pub const call_name = "ai_infer";

/// The number of the call in the system call interface.
pub const call_number: u64 = 24;

/// The kind of the capability that authorizes the call, as written in the
/// register of `grant` and `revoke`.
pub const capability_kind_wire: u64 = 4;

/// The name of the capability kind, for the diagnostics.
pub const capability_kind_name = "ai";

/// The right that authorizes the inference.
pub const right_execute: u64 = 1 << 5;

/// The identifier of the embedded model.
///
/// The kernel has a single model, and the identifier exists so that a future
/// version can add models without changing the number of the call. The value
/// zero is the only one accepted by this version.
pub const model_id: u64 = 0;

/// Number of input features of the embedded model.
pub const input_dims: usize = 4;

/// Number of output features of the embedded model.
pub const output_dims: usize = 3;

/// Number of bytes that the caller sends.
pub const input_bytes: usize = input_dims * @sizeOf(f32);

/// Number of bytes that the caller receives.
pub const output_bytes: usize = output_dims * @sizeOf(f32);

/// The input that the boot self-test and the native application send.
pub const sample_input: [input_dims]f32 = .{ 1.0, 2.0, 3.0, 4.0 };

/// The exact result of the embedded model over `sample_input`.
pub const expected_output: [output_dims]f32 = .{ 2.125, 5.25, 4.0 };

const fnv_offset_basis: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

/// FNV-1a over the bytes of the values.
///
/// The checksum is what the kernel, the application and the boot test
/// compare. It is not a security primitive: it detects a wrong value, a
/// wrong count or a lost write, and it does not pretend to be a MAC.
pub fn checksumOf(values: []const f32) u64 {
    var hash: u64 = fnv_offset_basis;
    for (values) |value| {
        const bytes: [4]u8 = @bitCast(value);
        for (bytes) |byte| {
            hash ^= byte;
            hash *%= fnv_prime;
        }
    }
    return hash;
}

/// The checksum of the expected output of the embedded model.
pub fn expectedChecksum() u64 {
    return checksumOf(&expected_output);
}

/// True when the values are bit exact with the expected output.
///
/// The comparison is on the bit pattern, and not on `==`: the contract
/// promises exact bytes, and `==` would accept `-0.0` for `0.0` and would
/// hide a difference in the sign of a zero result.
pub fn matchesExpected(values: []const f32) bool {
    if (values.len < output_dims) return false;
    for (0..output_dims) |index| {
        if (@as(u32, @bitCast(values[index])) != @as(u32, @bitCast(expected_output[index])))
            return false;
    }
    return true;
}

test "the checksum of the expected output is stable and detects a change" {
    try std.testing.expectEqual(@as(u64, 0x30f2bf7325eecf35), expectedChecksum());

    var copy: [output_dims]f32 = expected_output;
    try std.testing.expect(matchesExpected(&copy));
    try std.testing.expectEqual(expectedChecksum(), checksumOf(&copy));

    copy[1] = 5.250001;
    try std.testing.expect(!matchesExpected(&copy));
    try std.testing.expect(expectedChecksum() != checksumOf(&copy));
}

test "a short buffer is not the expected output" {
    const short: [output_dims - 1]f32 = .{ 2.125, 5.25 };
    try std.testing.expect(!matchesExpected(&short));
}

test "the negative zero is not the zero of the contract" {
    var values: [output_dims]f32 = expected_output;
    values[2] = -0.0;
    try std.testing.expect(!matchesExpected(&values));
}

test "the geometry of the contract is coherent" {
    try std.testing.expectEqual(@as(usize, 16), input_bytes);
    try std.testing.expectEqual(@as(usize, 12), output_bytes);
    try std.testing.expectEqual(@as(usize, 4), sample_input.len);
    try std.testing.expectEqual(@as(usize, 3), expected_output.len);
}
