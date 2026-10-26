//************************************************************************//
//  compositor.zig                                                        //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Contrato público entre o cliente e o compositor do F6.29.
//!
//! O cliente recebe uma página de contrato somente leitura abaixo da própria
//! janela. A página informa qual processo compõe o quadro, qual canal entrega
//! o aviso de quadro pronto e onde fica a superfície do compositor. O cliente
//! não recebe a página da superfície: ele escreve nela por `copy_to`, com a
//! capability de escrita sobre o processo do compositor.
//!
//! A superfície e a página de contrato ficam imediatamente abaixo da janela
//! de modo usuário, dentro do mesmo bloco de dois megabytes. O materializador
//! não as conhece; o kernel as mapeia nos espaços certos e verifica as
//! permissões antes de criar as tarefas.

const std = @import("std");
const usermode = @import("usermode.zig");

/// A página de contrato fica esta distância abaixo da base da janela.
pub const contract_below: u64 = usermode.contract_below;

/// A superfície do compositor fica esta distância abaixo da base da janela.
pub const surface_below: u64 = usermode.surface_below;

/// Versão do contrato do cliente.
pub const contract_version: u64 = 1;

/// Canal usado pelo cliente para avisar o compositor.
pub const channel_id: u64 = 2;

/// Lado do canal que pertence ao compositor. O cliente envia para este lado
/// e o compositor recebe deste lado.
pub const compositor_side: u64 = 0;
/// Lado que pertence ao cliente para receber o ACK do compositor.
pub const client_side: u64 = 1;

/// Tipo da mensagem de quadro pronto.
pub const frame_ready_kind: u64 = 0x4652_414D_4531; // "FRAME1"

/// Tipo de mensagem que libera o cliente após a primeira composição.
pub const compositor_ready_kind: u64 = 0x434F_4D50_524459; // "COMPRDY"

/// Tipo da mensagem de posicionamento de janela.
///
/// O cliente envia esta mensagem antes de aguardar o ACK e copiar os pixels
/// da janela para a superfície do compositor. O valor é a geometria empacotada
/// (x, y, largura, altura como u16).
pub const window_place_kind: u64 = 0x574E_4450_4C41_4345; // "WNDPLACE"

/// Empacota a geometria de uma janela no valor da mensagem de posicionamento.
pub fn packWindow(x: u16, y: u16, width: u16, height: u16) u64 {
    return @as(u64, x) | (@as(u64, y) << 16) | (@as(u64, width) << 32) | (@as(u64, height) << 48);
}

/// Desempacota a geometria de uma janela do valor da mensagem.
pub const WindowGeometry = extern struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub fn unpackWindow(value: u64) WindowGeometry {
    return .{
        .x = @truncate(value),
        .y = @truncate(value >> 16),
        .width = @truncate(value >> 32),
        .height = @truncate(value >> 48),
    };
}

/// Reject empty or out-of-bounds rectangles without overflowing x + width.
/// Use this for every untrusted WNDPLACE message before reading pixels.
pub fn validWindow(geometry: WindowGeometry, surface_w: u32, surface_h: u32) bool {
    const x: u32 = geometry.x;
    const y: u32 = geometry.y;
    const w: u32 = geometry.width;
    const h: u32 = geometry.height;
    return w != 0 and h != 0 and x < surface_w and y < surface_h and
        w <= surface_w - x and h <= surface_h - y;
}

test "window placement rejects empty, clipped and overflowing rectangles" {
    try std.testing.expect(validWindow(unpackWindow(packWindow(8, 8, 16, 16)), 32, 24));
    try std.testing.expect(validWindow(unpackWindow(packWindow(0, 0, 32, 24)), 32, 24));
    try std.testing.expect(!validWindow(unpackWindow(packWindow(0, 0, 0, 1)), 32, 24));
    try std.testing.expect(!validWindow(unpackWindow(packWindow(31, 0, 2, 1)), 32, 24));
    try std.testing.expect(!validWindow(unpackWindow(packWindow(0, 23, 1, 2)), 32, 24));
    try std.testing.expect(!validWindow(unpackWindow(packWindow(65535, 0, 65535, 1)), 32, 24));
}

/// Largura da superfície do compositor, em pixels.
pub const surface_width: u32 = 32;

/// Altura da superfície do compositor, em pixels.
pub const surface_height: u32 = 24;

/// Distância entre duas linhas da superfície, em pixels.
pub const surface_stride: u32 = surface_width;

/// Tamanho da superfície, em bytes.
pub const surface_size: u64 = @as(u64, surface_width) * @as(u64, surface_height) * 4;

/// Coluna da janela do cliente dentro da superfície.
pub const client_x: u32 = 8;

/// Linha da janela do cliente dentro da superfície.
pub const client_y: u32 = 8;

/// Largura da janela do cliente, em pixels.
pub const client_width: u32 = 16;

/// Altura da janela do cliente, em pixels.
pub const client_height: u32 = 16;

/// Conteúdo da página de contrato do cliente.
///
/// Todos os campos são palavras de 64 bits para que o layout seja o mesmo no
/// kernel e nos dois aplicativos, independentemente do compilador. O kernel
/// preenche a página, protege-a como somente leitura e só então cria a tarefa
/// do cliente.
pub const Contract = extern struct {
    version: u64,
    compositor_process: u64,
    channel_id: u64,
    surface_address: u64,
    surface_width: u64,
    surface_height: u64,
    surface_stride: u64,
    surface_bytes: u64,
    frame_ready_kind: u64,
};

/// Validate the read-only client contract before any cross-process copy.
/// Bounds are checked with subtraction to avoid address arithmetic overflow.
pub fn validContract(contract: Contract) bool {
    if (contract.version != contract_version or
        contract.channel_id != channel_id or
        contract.frame_ready_kind != frame_ready_kind or
        contract.surface_width != surface_width or
        contract.surface_height != surface_height or
        contract.surface_stride != surface_stride or
        contract.surface_bytes != surface_size or
        contract.surface_address == 0 or
        contract.compositor_process == 0)
    {
        return false;
    }
    // A surface must fit inside its own mapped page, including the last byte.
    if (contract.surface_address % 0x1000 != 0) return false;
    if (contract.surface_bytes > 0x1000) return false;
    return contract.surface_address <= ~@as(u64, 0) - contract.surface_bytes;
}

test "client contract rejects inconsistent and unaligned surface metadata" {
    const good: Contract = .{
        .version = contract_version,
        .compositor_process = 4,
        .channel_id = channel_id,
        .surface_address = 0x17f8000,
        .surface_width = surface_width,
        .surface_height = surface_height,
        .surface_stride = surface_stride,
        .surface_bytes = surface_size,
        .frame_ready_kind = frame_ready_kind,
    };
    try std.testing.expect(validContract(good));
    var bad = good;
    bad.surface_address = 0;
    try std.testing.expect(!validContract(bad));
    bad = good;
    bad.surface_address = 0xffffffffffffffff;
    try std.testing.expect(!validContract(bad));
    bad = good;
    bad.surface_stride += 1;
    try std.testing.expect(!validContract(bad));
    bad = good;
    bad.compositor_process = 0;
    try std.testing.expect(!validContract(bad));
}

test "contract layout is stable and fits one page" {
    try std.testing.expectEqual(@as(usize, 9 * 8), @sizeOf(Contract));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Contract));
    try std.testing.expect(@sizeOf(Contract) <= 0x1000);
    try std.testing.expectEqual(@as(u64, 1), contract_version);
    try std.testing.expect(channel_id < 4);
    try std.testing.expect(compositor_side < 2);
    try std.testing.expect(frame_ready_kind != 0);
}

test "surface and client rectangle are consistent" {
    try std.testing.expectEqual(@as(u64, 32 * 24 * 4), surface_size);
    try std.testing.expect(surface_stride >= surface_width);
    try std.testing.expect(surface_size <= 0x1000);
    try std.testing.expect(client_x + client_width <= surface_width);
    try std.testing.expect(client_y + client_height <= surface_height);
    try std.testing.expect(client_width > 0);
    try std.testing.expect(client_height > 0);
}
