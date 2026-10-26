//************************************************************************//
//  tensor.zig                                                            //
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

//! Operacoes tensoriais fundamentais em espaco de usuario (ABI v13).
//! Nenhuma dependência do kernel; alocacao explicita via buffer do chamador.

const std = @import("std");

pub const Error = error{
    DimensionMismatch,
    Overflow,
    OutOfMemory,
};

/// Multiplica matrizes A (M x K) * B (K x N) -> C (M x N).
/// Todos os buffers sao fornecidos pelo chamador (isolamento de memoria).
pub fn matMul(A: []const f32, B: []const f32, C: []f32, M: usize, K: usize, N: usize) Error!void {
    const mk = std.math.mul(usize, M, K) catch return error.Overflow;
    const kn = std.math.mul(usize, K, N) catch return error.Overflow;
    const mn = std.math.mul(usize, M, N) catch return error.Overflow;
    if (A.len < mk or B.len < kn or C.len < mn) return error.DimensionMismatch;
    for (0..M) |i| {
        for (0..N) |j| {
            var sum: f32 = 0.0;
            for (0..K) |k| {
                sum += A[i * K + k] * B[k * N + j];
            }
            C[i * N + j] = sum;
        }
    }
}

/// ReLU: max(0, x) vetorial.
pub fn relu(x: []f32) void {
    for (x) |*v| {
        if (v.* < 0.0) v.* = 0.0;
    }
}

test "matMulAndReluReal" {
    // 2x2 * 2x2 = 2x2
    const A = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const B = [_]f32{ 5.0, 6.0, 7.0, 8.0 };
    var C: [4]f32 = undefined;
    try matMul(&A, &B, &C, 2, 2, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 19.0), C[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 22.0), C[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 43.0), C[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), C[3], 0.001);

    var v = [_]f32{ -1.0, 0.5, -3.0, 2.0 };
    relu(&v);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), v[1], 0.001);
}
