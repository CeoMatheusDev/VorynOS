//************************************************************************//
//  client.zig                                                            //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Cliente do compositor do F6.30.
//!
//! O processo compõe um quadro de 32x24 e comunica a geometria da janela ao
//! compositor por IPC antes de copiar os pixels por `copy_to`. A capability
//! de escrita sobre o processo do compositor autoriza a cópia; a capability
//! do canal 2 autoriza o aviso de quadro pronto. O cliente não possui display
//! nem entrada.
//!
//! A superfície não é compartilhada: o kernel copia cada linha para a página
//! do compositor. O compartilhamento direto de memória continua fora do
//! contrato atual.

const std = @import("std");
const sdk = @import("voryn_sdk");
const composition = @import("composition.zig");

/// A base da janela, gravada pelo stub de entrada em assembly.
export var voryn_user_window_base: u64 = 0;

/// O papel do processo, gravado pelo stub de entrada em assembly.
export var voryn_user_role: u64 = 0;

const frame_background: u32 = 0x00303030;
const frame_windows = [_]composition.Window{
    .{ .x = 0, .y = 0, .width = 16, .height = 16, .color = 0x00808080 },
    .{ .x = 4, .y = 4, .width = 8, .height = 8, .color = 0x00E0E0E0 },
    .{ .x = 8, .y = 8, .width = 4, .height = 4, .color = 0x00404040 },
};

export fn voryn_user_main(window_base: u64, role: u64) noreturn {
    _ = role;

    if (sdk.ping() != 0x42) sdk.exit(2);

    if (window_base <= sdk.compositor.contract_below) sdk.exit(3);

    const contract_address = window_base - sdk.compositor.contract_below;
    const contract: *const sdk.compositor.Contract =
        @ptrFromInt(@as(usize, @intCast(contract_address)));
    if (!sdk.compositor.validContract(contract.*))
    {
        sdk.exit(4);
    }

    // Compos um quadro de 32x24 na pilha.
    var full_frame: [sdk.compositor.surface_width * sdk.compositor.surface_height]u32 = undefined;
    var surface = composition.Surface.init(
        &full_frame,
        sdk.compositor.surface_width,
        sdk.compositor.surface_height,
        sdk.compositor.surface_stride,
    ) catch sdk.exit(5);
    surface.compose(frame_background, &frame_windows);

    // Copia cada linha da janela (16 rows x 64 bytes) da região (8,8) do
    // quadro local para a superfície do compositor na posição (8,8).
    var row: u32 = 0;
    while (row < 16) : (row += 1) {
        const source_row = (@as(u64, sdk.compositor.client_y + row) * sdk.compositor.surface_stride + sdk.compositor.client_x);
        const destination = contract.surface_address +
            (@as(u64, sdk.compositor.client_y + row) * contract.surface_stride +
                sdk.compositor.client_x) * 4;
        const source = std.mem.sliceAsBytes(
            full_frame[source_row .. source_row + sdk.compositor.client_width],
        );
        const status = sdk.copyTo(contract.compositor_process, destination, source);
        if (sdk.syscall.isError(status) or status != source.len) sdk.exit(6);
    }

    // Calcula o checksum da região da janela (x=8, y=8, 16x16) sobre o
    // quadro completo e o envia como valor do aviso de quadro pronto. O
    // compositor confere o mesmo hash sobre a superfície antes de publicar.
    var full_surface = composition.Surface.init(
        &full_frame,
        sdk.compositor.surface_width,
        sdk.compositor.surface_height,
        sdk.compositor.surface_stride,
    ) catch sdk.exit(7);
    const client_hash = full_surface.checksumRegion(
        sdk.compositor.client_x,
        sdk.compositor.client_y,
        sdk.compositor.client_width,
        sdk.compositor.client_height,
    ) orelse sdk.exit(7);

    // Record the computed hash before the IPC handoff for diagnostics.
    _ = sdk.write("client checksum computed\n");

    // Posiciona a janela no compositor antes de avisar que o quadro está pronto.
    const placement = sdk.compositor.packWindow(
        sdk.compositor.client_x,
        sdk.compositor.client_y,
        sdk.compositor.client_width,
        sdk.compositor.client_height,
    );
    const placed = sdk.send(
        contract.channel_id,
        sdk.compositor.compositor_side,
        sdk.compositor.window_place_kind,
        placement,
    );
    if (sdk.syscall.isError(placed) or placed != 0) sdk.exit(7);

    // Avisa o compositor com o kind FRAME1 e o checksum da região.
    const sent = sdk.send(
        contract.channel_id,
        sdk.compositor.compositor_side,
        sdk.compositor.frame_ready_kind,
        client_hash,
    );
    if (sdk.syscall.isError(sent) or sent != 0) sdk.exit(8);

    sdk.exit(0);
}