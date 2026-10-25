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

    // Aguarda a composição inicial antes de escrever na superfície remota.
    const ready = sdk.receiveBlocking(
        contract.channel_id,
        sdk.compositor.client_side,
    );
    if (sdk.syscall.isError(ready.status) or ready.status != sdk.compositor.compositor_ready_kind) sdk.exit(6);

    // Copia o quadro completo para a superfície do compositor em uma única
    // operação validada.
    const source = std.mem.sliceAsBytes(&full_frame);
    const status = sdk.copyTo(contract.compositor_process, contract.surface_address, source);
    if (sdk.syscall.isError(status) or status != source.len) sdk.exit(6);

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
    var hash_text: [17]u8 = undefined;
    var digit: usize = 0;
    while (digit < 16) : (digit += 1) {
        const shift: u6 = @intCast((15 - digit) * 4);
        const nibble: usize = @intCast((client_hash >> shift) & 0xf);
        hash_text[digit] = "0123456789abcdef"[nibble];
    }
    hash_text[16] = '\n';
    _ = sdk.write("client checksum=0x");
    _ = sdk.write(&hash_text);

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