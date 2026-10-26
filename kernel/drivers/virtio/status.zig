//************************************************************************//
//  status.zig                                                            //
//************************************************************************//
//                        This file is part of:                           //
//                              VorynOS                                   //
//             https://github.com/CeoMatheusDev/VorynOS                       //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 VorynOS - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! Estados da inicializacao VirtIO e transicoes validas.
//!
//! O campo `device status` e um conjunto de bits que o driver so acrescenta.
//! A sequencia exigida pela especificacao (secao 2.4 e 3.1.1) e:
//!
//! ```text
//!   0 -> ACKNOWLEDGE -> DRIVER -> FEATURES_OK -> DRIVER_OK
//! ```
//!
//! O driver nao limpa bits: recomecar significa escrever 0, o que e um reset
//! do dispositivo, e nao uma transicao para um estado anterior. O bit FAILED
//! pode ser escrito a partir de qualquer estado, e depois dele apenas o reset
//! e aceito. O bit DEVICE_NEEDS_RESET pertence ao dispositivo; um driver que
//! o escreve esta violando a especificacao e recebe um erro explicito.
//!
//! Este modulo nao acessa o dispositivo: ele valida a sequencia que a
//! camada de transporte vai executar quando o registro for programado.

const std = @import("std");

/// O sistema encontrou o dispositivo e o reconheceu como VirtIO.
pub const acknowledge: u8 = 1 << 0;
/// O sistema sabe como conduzir o dispositivo.
pub const driver: u8 = 1 << 1;
/// O driver terminou a configuracao e pode usar o dispositivo.
pub const driver_ok: u8 = 1 << 2;
/// O driver terminou a negociacao de features.
pub const features_ok: u8 = 1 << 3;
/// Suspensao do dispositivo; exige VIRTIO_F_SUSPEND.
pub const suspended: u8 = 1 << 4;
/// O dispositivo encontrou um erro que so um reset resolve.
pub const device_needs_reset: u8 = 1 << 6;
/// O driver desistiu do dispositivo.
pub const failed: u8 = 1 << 7;

/// Todos os bits definidos pela especificacao.
pub const defined_mask: u8 = acknowledge | driver | driver_ok | features_ok |
    suspended | device_needs_reset | failed;

/// Bits que o driver escreve.
pub const driver_mask: u8 = acknowledge | driver | driver_ok | features_ok | failed;

/// Bits que somente o dispositivo escreve.
pub const device_mask: u8 = device_needs_reset;

/// Estados alcancaveis, um por valor valido do campo.
pub const Phase = enum {
    /// Nenhum bit ligado; o dispositivo acabou de ser reiniciado.
    reset,
    acknowledge,
    driver,
    features_ok,
    driver_ok,
    /// DRIVER_OK com DEVICE_NEEDS_RESET: o dispositivo pediu reset.
    device_needs_reset,
    failed,
};

pub const Error = error{
    /// Um bit nao definido pela especificacao esta ligado.
    ReservedBitSet,
    /// VIRTIO_F_SUSPEND nao e negociado por este subsistema.
    SuspendUnsupported,
    /// Os bits ligados nao formam um estado da sequencia.
    InvalidCombination,
    /// A transicao pula um passo, volta atras ou nao existe.
    IllegalTransition,
    /// O driver tentou escrever o bit do dispositivo.
    DeviceBitWrittenByDriver,
};

/// Interpreta o valor do campo `device status`.
///
/// Devolve o estado correspondente ao conjunto de bits, ou um erro quando os
/// bits nao descrevem um estado possivel. FAILED tem precedencia: depois de
/// desistir do dispositivo, os demais bits nao descrevem mais nada util e um
/// reset e necessario antes de qualquer nova tentativa.
pub fn phase(state: u8) Error!Phase {
    if (state & ~defined_mask != 0) return error.ReservedBitSet;
    if (state & suspended != 0) return error.SuspendUnsupported;
    if (state & failed != 0) return .failed;

    const needs_reset = state & device_needs_reset != 0;
    const reached: Phase = switch (state & ~device_needs_reset) {
        0 => .reset,
        acknowledge => .acknowledge,
        acknowledge | driver => .driver,
        acknowledge | driver | features_ok => .features_ok,
        acknowledge | driver | features_ok | driver_ok => .driver_ok,
        else => return error.InvalidCombination,
    };

    // O dispositivo so sinaliza DEVICE_NEEDS_RESET depois que o driver
    // publicou DRIVER_OK; antes disso o bit nao faz sentido.
    if (needs_reset) {
        if (reached != .driver_ok) return error.InvalidCombination;
        return .device_needs_reset;
    }
    return reached;
}

/// Valor do campo `device status` correspondente ao estado.
pub fn bitsOf(state: Phase) u8 {
    return switch (state) {
        .reset => 0,
        .acknowledge => acknowledge,
        .driver => acknowledge | driver,
        .features_ok => acknowledge | driver | features_ok,
        .driver_ok => acknowledge | driver | features_ok | driver_ok,
        .device_needs_reset => acknowledge | driver | features_ok | driver_ok | device_needs_reset,
        .failed => failed,
    };
}

/// Proximo estado da sequencia, ou null quando a sequencia terminou.
pub fn nextPhase(current: Phase) ?Phase {
    return switch (current) {
        .reset => .acknowledge,
        .acknowledge => .driver,
        .driver => .features_ok,
        .features_ok => .driver_ok,
        .driver_ok, .device_needs_reset, .failed => null,
    };
}

/// Valida a escrita de `to` sobre o estado `from` e devolve o estado obtido.
///
/// Regras aplicadas, todas derivadas da especificacao:
///
///   * escrever 0 e o reset do dispositivo, aceito de qualquer estado;
///   * FAILED e aceito de qualquer estado, porque o driver pode desistir a
///     qualquer momento;
///   * a sequencia avanca um passo por vez e nunca retrocede;
///   * repetir o valor atual e aceito e nao altera o estado;
///   * DEVICE_NEEDS_RESET nunca e escrito pelo driver;
///   * depois de FAILED, so o reset e aceito.
pub fn transition(from: u8, to: u8) Error!Phase {
    const current = try phase(from);
    const desired = try phase(to);

    if (desired == .device_needs_reset) return error.DeviceBitWrittenByDriver;
    if (desired == .reset) return .reset;
    if (desired == .failed) return .failed;

    if (current == .failed or current == .device_needs_reset) {
        return error.IllegalTransition;
    }
    if (current == desired) return desired;

    const required = nextPhase(current) orelse return error.IllegalTransition;
    if (desired != required) return error.IllegalTransition;
    return desired;
}

/// True quando o dispositivo esta em DRIVER_OK e sem erro pendente.
pub fn isReady(state: u8) bool {
    const current = phase(state) catch return false;
    return current == .driver_ok;
}

const testing = std.testing;

test "virtio status bits match the specification" {
    try testing.expectEqual(@as(u8, 0x01), acknowledge);
    try testing.expectEqual(@as(u8, 0x02), driver);
    try testing.expectEqual(@as(u8, 0x04), driver_ok);
    try testing.expectEqual(@as(u8, 0x08), features_ok);
    try testing.expectEqual(@as(u8, 0x10), suspended);
    try testing.expectEqual(@as(u8, 0x40), device_needs_reset);
    try testing.expectEqual(@as(u8, 0x80), failed);
    try testing.expectEqual(@as(u8, 0xDF), defined_mask);
}

test "virtio status requires the documented sequence" {
    try testing.expectEqual(Phase.reset, try phase(0));

    var state: u8 = 0;
    const sequence = [_]Phase{ .acknowledge, .driver, .features_ok, .driver_ok };
    for (sequence) |expected| {
        state = bitsOf(try transition(state, bitsOf(expected)));
        try testing.expectEqual(expected, try phase(state));
    }
    try testing.expectEqual(@as(u8, 0x0F), state);
    try testing.expect(isReady(state));
    try testing.expect(!isReady(0));

    // O estado final da sequencia nao avanca mais.
    try testing.expect(nextPhase(.driver_ok) == null);
    try testing.expectError(error.IllegalTransition, transition(state, bitsOf(.acknowledge)));
}

test "virtio status rejects skipped, backwards and reserved values" {
    // Pular passos.
    try testing.expectError(error.IllegalTransition, transition(0, bitsOf(.driver)));
    try testing.expectError(error.IllegalTransition, transition(0, bitsOf(.driver_ok)));
    try testing.expectError(
        error.IllegalTransition,
        transition(bitsOf(.acknowledge), bitsOf(.features_ok)),
    );

    // Voltar atras sem reset.
    try testing.expectError(
        error.IllegalTransition,
        transition(bitsOf(.features_ok), bitsOf(.driver)),
    );
    try testing.expectError(
        error.IllegalTransition,
        transition(bitsOf(.driver_ok), bitsOf(.features_ok)),
    );

    // Bits reservados (5, 7) e suspensao, que nao e negociada.
    try testing.expectError(error.ReservedBitSet, phase(0x20));
    try testing.expectError(error.ReservedBitSet, phase(0x0F | 0x20));
    try testing.expectError(error.SuspendUnsupported, phase(suspended));

    // Combinacoes que nao existem na sequencia.
    try testing.expectError(error.InvalidCombination, phase(driver));
    try testing.expectError(error.InvalidCombination, phase(acknowledge | driver_ok));
    try testing.expectError(error.InvalidCombination, phase(device_needs_reset));
}

test "virtio status reset and failure are always available" {
    const states = [_]u8{
        0,
        bitsOf(.acknowledge),
        bitsOf(.driver),
        bitsOf(.features_ok),
        bitsOf(.driver_ok),
        bitsOf(.device_needs_reset),
    };
    for (states) |state| {
        try testing.expectEqual(Phase.reset, try transition(state, 0));
        try testing.expectEqual(Phase.failed, try transition(state, failed));
    }

    // Depois de FAILED, so o reset e aceito.
    try testing.expectError(error.IllegalTransition, transition(failed, acknowledge));
    try testing.expectError(error.IllegalTransition, transition(failed, bitsOf(.driver_ok)));
    try testing.expectEqual(Phase.reset, try transition(failed, 0));

    // Repetir o valor atual nao e uma transicao ilegal.
    try testing.expectEqual(Phase.driver, try transition(bitsOf(.driver), bitsOf(.driver)));
}

test "virtio status never accepts the device bit from the driver" {
    try testing.expectError(
        error.DeviceBitWrittenByDriver,
        transition(bitsOf(.driver_ok), bitsOf(.device_needs_reset)),
    );
    try testing.expectError(
        error.DeviceBitWrittenByDriver,
        transition(0, bitsOf(.device_needs_reset)),
    );

    // O estado em que o dispositivo pede reset nao aceita avanco.
    const needs_reset = bitsOf(.device_needs_reset);
    try testing.expectEqual(Phase.device_needs_reset, try phase(needs_reset));
    try testing.expect(!isReady(needs_reset));
    try testing.expectEqual(Phase.reset, try transition(needs_reset, 0));
    try testing.expectEqual(Phase.failed, try transition(needs_reset, failed));
    try testing.expectError(
        error.IllegalTransition,
        transition(needs_reset, bitsOf(.driver_ok)),
    );
}
