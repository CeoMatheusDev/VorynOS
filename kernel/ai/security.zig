//************************************************************************//
//  security.zig — F9.3 políticas de segurança e cotas de memória (VorynOS) //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                   //
//************************************************************************//

//! Políticas defensivas para inferência nativa F9.
//! Nenhuma afirmação de NX/W^X é feita aqui; esses pertencem ao
//! subsistema de memória virtual (paging.zig / kernel). F9.3 valida
//! limites de buffer, dimensões e overflow aritmético before execution.

const std = @import("std");

pub const Limits = struct {
    max_model_bytes: usize = 256 * 1024 * 1024, // 256 MiB default
    max_tensor_elements: usize = 1024 * 1024,     // 1M elementos
    max_layers: u16 = 16,
    max_workspace_bytes: usize = 512 * 1024 * 1024, // 512 MiB
    max_total_bytes: usize = 512 * 1024 * 1024,
};

pub const Error = error{
    ModelTooLarge,
    TensorTooLarge,
    TooManyLayers,
    WorkspaceTooLarge,
    TotalTooLarge,
    DimensionOverflow,
    InvalidDimension,
};

/// Valida que o tamanho do buffer do modelo cabe dentro do limite.
pub fn validateModelSize(buf_len: usize, limits: Limits) Error!void {
    if (buf_len > limits.max_model_bytes) return error.ModelTooLarge;
}

/// Valida dimensões de tensores com verificação de overflow.
pub fn validateTensorShape(input_dims: usize, hidden_dims: usize, output_dims: usize, limits: Limits) Error!void {
    if (input_dims == 0 or hidden_dims == 0 or output_dims == 0) return error.InvalidDimension;
    if (input_dims > limits.max_tensor_elements) return error.TensorTooLarge;
    if (hidden_dims > limits.max_tensor_elements) return error.TensorTooLarge;
    if (output_dims > limits.max_tensor_elements) return error.TensorTooLarge;
    _ = std.math.mul(usize, input_dims, hidden_dims) catch return error.DimensionOverflow;
    _ = std.math.mul(usize, hidden_dims, output_dims) catch return error.DimensionOverflow;
}

/// Valida espaço de trabalho antes de alocação.
pub fn validateWorkspace(required_bytes: usize, limits: Limits) Error!void {
    if (required_bytes > limits.max_workspace_bytes) return error.WorkspaceTooLarge;
}

/// Valida limite total (modelo + workspace) sem overflow.
pub fn validateTotal(model_bytes: usize, workspace_bytes: usize, limits: Limits) Error!void {
    const total = std.math.add(usize, model_bytes, workspace_bytes) catch return error.TotalTooLarge;
    if (total > limits.max_total_bytes) return error.TotalTooLarge;
}

test "securityLimitsRejectOversize" {
    const l: Limits = .{
        .max_model_bytes = 1024,
        .max_tensor_elements = 16,
        .max_layers = 2,
        .max_workspace_bytes = 1024,
        .max_total_bytes = 2048,
    };
    // Modelo acima do limite
    try std.testing.expectError(error.ModelTooLarge, validateModelSize(2048, l));
    // Tensor com dimensão grande
    try std.testing.expectError(error.TensorTooLarge, validateTensorShape(20, 2, 2, l));
    // Overflow de dimensão
    try std.testing.expectError(error.DimensionOverflow, validateTensorShape(100_000, 100_000, 100_000, .{}));
    // Workspace acima do limite
    try std.testing.expectError(error.WorkspaceTooLarge, validateWorkspace(2048, l));
    // Total acima do limite
    try std.testing.expectError(error.TotalTooLarge, validateTotal(1024, 1024, Limits{ .max_total_bytes = 1024 }));
}
